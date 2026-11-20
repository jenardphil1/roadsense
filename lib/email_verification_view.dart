import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cloud_service.dart';
import 'email_verification_client.dart';
import 'app_design.dart';
import 'mobile_components.dart';

/// Prompts the current user to verify their email via the Firebase verification
/// link before submitting or saving a pothole report. Returns `true` if the
/// user is already verified or completes verification inside the dialog.
Future<bool> showEmailVerificationRequiredDialog(
  BuildContext context, {
  required bool isDark,
  EmailVerificationBackend? backend,
  String? initialEmail,
  Future<bool> Function()? checkVerified,
  Future<void> Function()? onSignOut,
}) async {
  final alreadyVerified =
      await (checkVerified ?? CloudService.instance.isEmailVerified)();
  if (alreadyVerified) return true;
  if (!context.mounted) return false;

  final resolvedBackend =
      backend ?? CloudService.instance.emailVerificationBackend;
  final resolvedEmail =
      initialEmail ?? CloudService.instance.currentUser?.email ?? 'your email';

  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: EmailVerificationView(
            backend: resolvedBackend,
            initialEmail: resolvedEmail,
            fetchStatusOnMount: true,
            autoSendIfMissing: true,
            isDark: isDark,
            headerNotice:
                'Email verification is required before sending a pothole report.',
            onCancel: () {
              if (ctx.mounted) Navigator.of(ctx).pop(false);
            },
            onVerified: () {
              if (ctx.mounted) Navigator.of(ctx).pop(true);
            },
            onSignOut: () async {
              if (ctx.mounted) Navigator.of(ctx).pop(false);
              await (onSignOut ?? CloudService.instance.signOut)();
            },
          ),
        ),
      ),
    ),
  );
  return result == true;
}

/// Shared, accessible "Verify your email" view that preserves RoadSense's
/// design tokens across mobile and web auth surfaces and enforces server-driven
/// cooldowns, expiry, rate limits, and secure pending email correction.
class EmailVerificationView extends StatefulWidget {
  final EmailVerificationBackend backend;
  final String initialEmail;
  final EmailVerificationStatus? initialStatus;
  final String? initialError;
  final String? initialInfo;
  final String? headerNotice;
  final bool fetchStatusOnMount;
  final bool autoSendIfMissing;
  final VoidCallback onVerified;
  final VoidCallback? onCancel;
  final Future<void> Function() onSignOut;
  final bool isDark;

  const EmailVerificationView({
    super.key,
    required this.backend,
    required this.initialEmail,
    this.initialStatus,
    this.initialError,
    this.initialInfo,
    this.headerNotice,
    this.fetchStatusOnMount = true,
    this.autoSendIfMissing = false,
    required this.onVerified,
    this.onCancel,
    required this.onSignOut,
    required this.isDark,
  });

  @override
  State<EmailVerificationView> createState() => _EmailVerificationViewState();
}

class _EmailVerificationViewState extends State<EmailVerificationView> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _changeEmailController = TextEditingController();
  final FocusNode _codeFocusNode = FocusNode();

  late EmailVerificationStatus _status;
  Timer? _tickTimer;
  int _pollTicks = 0;
  bool _isPolling = false;

  bool _isLoadingStatus = false;
  bool _isVerifying = false;
  bool _isResending = false;
  bool _isUpdatingEmail = false;
  bool _isSigningOut = false;
  bool _showChangeEmail = false;

  String? _errorMessage;
  String? _infoMessage;
  String? _inlineCodeError;
  String? _changeEmailError;

  bool get _anyInFlight =>
      _isVerifying || _isResending || _isUpdatingEmail || _isSigningOut;

  @override
  void initState() {
    super.initState();
    _status =
        widget.initialStatus ??
        EmailVerificationStatus(
          verified: false,
          maskedEmail: maskEmailAddress(widget.initialEmail),
          hasActiveCode: widget.initialError == null,
          isExpired: false,
          expiresAtMs: 0,
          cooldownUntilMs: 0,
          attemptsRemaining: 5,
          isLockedOut: false,
          sendLimitReached: false,
          sendsInWindow: 0,
          maxSendsPerWindow: 5,
          ttlMinutes: 10,
        );
    _errorMessage = widget.initialError;
    if (_errorMessage == null &&
        (_status.usesEmailLinkFallback ||
            (_status.devPreviewCode?.isNotEmpty ?? false))) {
      _infoMessage = _buildSentInfoMessage(_status);
    } else {
      _infoMessage = widget.initialInfo;
    }
    _startCountdownTicker();
    if (widget.fetchStatusOnMount) {
      unawaited(_syncServerStatus());
    }
  }

  String _buildSentInfoMessage(
    EmailVerificationStatus status, {
    bool isResend = false,
  }) {
    if (status.usesEmailLinkFallback) {
      return 'A verification email was sent to ${status.maskedEmail}. Click the link in your inbox (or Spam/Junk), then tap Verify.';
    }
    final base = isResend
        ? 'A new 6-digit code was sent to ${status.maskedEmail}. Any previous code is no longer valid.'
        : 'A 6-digit verification code was sent to ${status.maskedEmail}.';
    final preview = status.devPreviewCode?.trim() ?? '';
    if (preview.isNotEmpty) {
      return '$base (Verification email sent — or use code: $preview)';
    }
    return base;
  }

  @override
  void didUpdateWidget(covariant EmailVerificationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialStatus != null &&
        widget.initialStatus != oldWidget.initialStatus) {
      _status = widget.initialStatus!;
    }
  }

  Future<void> _pollVerificationStatus() async {
    _isPolling = true;
    try {
      final fetched = await widget.backend.getStatus();
      if (!mounted) return;
      if (fetched.verified) {
        widget.onVerified();
      }
    } catch (_) {
      // Silent background poll; ignore transient failures.
    } finally {
      _isPolling = false;
    }
  }

  void _startCountdownTicker() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      final hasCooldown = _status.remainingCooldownSeconds(now) > 0;
      final hasExpiry = _status.remainingExpirySeconds(now) > 0;
      if (hasCooldown ||
          hasExpiry ||
          (_status.hasActiveCode && !_status.isExpired)) {
        setState(() {
          if (_status.hasActiveCode &&
              _status.expiresAtMs > 0 &&
              _status.remainingExpirySeconds(now) == 0) {
            _status = _status.copyWith(hasActiveCode: false, isExpired: true);
          }
        });
      }
      _pollTicks++;
      if (widget.backend is FirebaseEmailVerificationBackend &&
          !_anyInFlight &&
          !_isLoadingStatus &&
          !_status.verified &&
          !_isPolling &&
          _pollTicks % 3 == 0) {
        unawaited(_pollVerificationStatus());
      }
    });
  }

  Future<void> _syncServerStatus() async {
    setState(() => _isLoadingStatus = true);
    try {
      var fetched = await widget.backend.getStatus();
      if (!mounted) return;
      if (fetched.verified) {
        widget.onVerified();
        return;
      }

      if (widget.autoSendIfMissing &&
          !fetched.hasActiveCode &&
          fetched.remainingCooldownSeconds() == 0 &&
          !fetched.sendLimitReached) {
        try {
          fetched = await widget.backend.sendCode();
          if (!mounted) return;
          if (fetched.verified) {
            widget.onVerified();
            return;
          }
          setState(() {
            _status = fetched;
            _infoMessage = _buildSentInfoMessage(fetched);
            _errorMessage = null;
          });
          return;
        } on EmailVerificationException catch (e) {
          if (!mounted) return;
          setState(() {
            _status = fetched;
            _applyExceptionToState(e);
          });
          return;
        }
      }

      setState(() {
        _status = fetched;
        if (fetched.isExpired && _errorMessage == null) {
          _errorMessage =
              'Your previous 6-digit code expired. Tap Resend code to get a new one.';
        } else if (fetched.isLockedOut && _errorMessage == null) {
          _errorMessage =
              'Too many incorrect attempts on the current code. Tap Resend code for a new one.';
        } else if (_errorMessage == null &&
            (fetched.usesEmailLinkFallback ||
                (fetched.devPreviewCode?.isNotEmpty ?? false))) {
          _infoMessage = _buildSentInfoMessage(fetched);
        }
      });
    } on EmailVerificationException catch (e) {
      if (!mounted) return;
      setState(() => _applyExceptionToState(e));
    } finally {
      if (mounted) {
        setState(() => _isLoadingStatus = false);
      }
    }
  }

  void _applyExceptionToState(EmailVerificationException e) {
    _errorMessage = e.message;
    _infoMessage = null;
    if (e.attemptsRemaining != null ||
        e.cooldownUntilMs != null ||
        e.expiresAtMs != null) {
      _status = _status.copyWith(
        attemptsRemaining: e.attemptsRemaining ?? _status.attemptsRemaining,
        cooldownUntilMs: e.cooldownUntilMs ?? _status.cooldownUntilMs,
        expiresAtMs: e.expiresAtMs ?? _status.expiresAtMs,
        isLockedOut: e.reason == 'attempt-limited' || e.attemptsRemaining == 0,
        isExpired: e.reason == 'expired' ? true : _status.isExpired,
        hasActiveCode: e.reason == 'expired' ? false : _status.hasActiveCode,
        sendLimitReached:
            e.reason == 'rate-limited' &&
                e.message.toLowerCase().contains('requested')
            ? true
            : _status.sendLimitReached,
      );
    }
    if (e.reason == 'cooldown' &&
        e.cooldownSeconds != null &&
        (e.cooldownUntilMs ?? 0) == 0) {
      _status = _status.copyWith(
        cooldownUntilMs:
            DateTime.now().millisecondsSinceEpoch + e.cooldownSeconds! * 1000,
      );
    }
  }

  Future<void> _submitVerify() async {
    if (_anyInFlight || _isLoadingStatus) return;
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      if (_status.usesEmailLinkFallback ||
          widget.backend is FirebaseEmailVerificationBackend) {
        setState(() {
          _isVerifying = true;
          _inlineCodeError = null;
          _errorMessage = null;
          _infoMessage = null;
        });
        try {
          final latest = await widget.backend.getStatus();
          if (!mounted) return;
          if (latest.verified) {
            widget.onVerified();
            return;
          }
          setState(() {
            _status = latest;
            if (latest.usesEmailLinkFallback) {
              _errorMessage =
                  'Click the verification link sent to ${latest.maskedEmail} (check Spam/Junk), then tap Verify again.';
            } else {
              _inlineCodeError =
                  'Enter all 6 digits from your verification email.';
            }
          });
          if (!latest.usesEmailLinkFallback) {
            _codeFocusNode.requestFocus();
          }
        } on EmailVerificationException catch (e) {
          if (!mounted) return;
          setState(() => _applyExceptionToState(e));
        } catch (_) {
          if (!mounted) return;
          setState(() {
            _inlineCodeError =
                'Enter all 6 digits from your verification email.';
          });
          _codeFocusNode.requestFocus();
        } finally {
          if (mounted) {
            setState(() => _isVerifying = false);
          }
        }
        return;
      }

      setState(() {
        _inlineCodeError = 'Enter all 6 digits from your verification email.';
      });
      _codeFocusNode.requestFocus();
      return;
    }

    setState(() {
      _isVerifying = true;
      _inlineCodeError = null;
      _errorMessage = null;
      _infoMessage = null;
    });

    try {
      final verified = await widget.backend.verifyCode(code);
      if (!mounted) return;
      if (verified) {
        widget.onVerified();
      } else {
        setState(() {
          _errorMessage =
              'Verification could not be finalized yet. Please try Verify again.';
        });
      }
    } on EmailVerificationException catch (e) {
      if (!mounted) return;
      // Preserve entered digits on network/transient errors and mild typos unless requested otherwise.
      setState(() => _applyExceptionToState(e));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Connection error. Check your internet connection and try again.';
        _infoMessage = null;
      });
    } finally {
      if (mounted) {
        setState(() => _isVerifying = false);
      }
    }
  }

  Future<void> _handleResend() async {
    if (_anyInFlight ||
        _isLoadingStatus ||
        _status.remainingCooldownSeconds() > 0 ||
        _status.sendLimitReached) {
      return;
    }

    setState(() {
      _isResending = true;
      _inlineCodeError = null;
      _errorMessage = null;
      _infoMessage = null;
    });

    try {
      final updated = await widget.backend.sendCode();
      if (!mounted) return;
      if (updated.verified) {
        widget.onVerified();
        return;
      }
      _codeController.clear();
      setState(() {
        _status = updated;
        _infoMessage = _buildSentInfoMessage(updated, isResend: true);
      });
    } on EmailVerificationException catch (e) {
      if (!mounted) return;
      setState(() => _applyExceptionToState(e));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Could not send a new verification code. Check your connection and try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _isResending = false);
      }
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final raw = data?.text ?? '';
      final match = RegExp(r'(\d{6})').firstMatch(raw);
      final digits = match != null
          ? match.group(1)!
          : raw.replaceAll(RegExp(r'[^0-9]'), '');
      final clamped = digits.length > 6 ? digits.substring(0, 6) : digits;
      if (!mounted) return;
      if (clamped.isEmpty) {
        setState(() {
          _inlineCodeError = 'No digits found on clipboard to paste.';
        });
        return;
      }
      _codeController.value = TextEditingValue(
        text: clamped,
        selection: TextSelection.collapsed(offset: clamped.length),
      );
      setState(() {
        _inlineCodeError = null;
        _errorMessage = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _inlineCodeError =
            'Unable to read clipboard. Type your 6-digit code manually.';
      });
    }
  }

  Future<void> _submitChangeEmail() async {
    if (_anyInFlight || _isLoadingStatus) return;
    final nextEmail = _changeEmailController.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(nextEmail)) {
      setState(() {
        _changeEmailError = 'Enter a valid email address.';
      });
      return;
    }

    setState(() {
      _isUpdatingEmail = true;
      _changeEmailError = null;
      _errorMessage = null;
      _infoMessage = null;
    });

    try {
      final updated = await widget.backend.updatePendingEmail(nextEmail);
      if (!mounted) return;
      _codeController.clear();
      _changeEmailController.clear();
      setState(() {
        _status = updated;
        _showChangeEmail = false;
        _infoMessage = _buildSentInfoMessage(updated, isResend: false)
            .replaceFirst(
              'A 6-digit verification code',
              'Email updated. A new 6-digit code',
            );
        if (updated.usesEmailLinkFallback) {
          _infoMessage =
              'Email updated. Click the verification link sent to ${updated.maskedEmail}, then tap Verify.';
        }
      });
    } on EmailVerificationException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.reason == 'invalid-email' ||
            e.reason == 'same-email' ||
            e.reason == 'email-in-use') {
          _changeEmailError = e.message;
        } else {
          _applyExceptionToState(e);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _changeEmailError =
            'Connection error while updating email. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _isUpdatingEmail = false);
      }
    }
  }

  Future<void> _handleSignOut() async {
    if (_isSigningOut) return;
    setState(() => _isSigningOut = true);
    try {
      await widget.onSignOut();
    } finally {
      if (mounted) setState(() => _isSigningOut = false);
    }
  }

  String _formatDuration(int totalSeconds) {
    final mins = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _codeController.dispose();
    _changeEmailController.dispose();
    _codeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final textPrimary = isDark
        ? const Color(0xFFF8FAFC)
        : const Color(0xFF0F172A);
    final textSecondary = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF475569);
    final brand = AppDesign.accent(isDark);
    const primaryFill = AppDesign.brand;
    final surfaceBorder = isDark
        ? const Color(0xFF334155)
        : const Color(0xFFE2E8F0);
    final inputFill = isDark
        ? const Color(0xFF0F172A)
        : const Color(0xFFF8FAFC);

    final now = DateTime.now();
    final cooldownSec = _status.remainingCooldownSeconds(now);
    final expirySec = _status.remainingExpirySeconds(now);
    final canResend =
        !_anyInFlight &&
        !_isLoadingStatus &&
        cooldownSec == 0 &&
        !_status.sendLimitReached;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Brand badge & title
        Row(
          children: [
            const RoadSenseLogo(size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                header: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Verify your email',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: textPrimary,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.headerNotice ??
                          (_status.usesEmailLinkFallback
                              ? 'Click the verification link sent to your email, then tap Verify below.'
                              : 'Enter the 6-digit code sent to your email.'),
                      style: TextStyle(
                        fontSize: 13.5,
                        color: textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.onCancel != null)
              IconButton(
                tooltip: 'Close',
                onPressed: _anyInFlight ? null : widget.onCancel,
                icon: Icon(Icons.close_rounded, color: textSecondary),
              ),
          ],
        ),

        const SizedBox(height: 16),

        // Masked email & server-synced expiry card
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: inputFill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: surfaceBorder),
          ),
          child: Row(
            children: [
              Icon(Icons.alternate_email_rounded, size: 18, color: brand),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _status.maskedEmail,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (_isLoadingStatus)
                      Text(
                        'Checking verification status…',
                        style: TextStyle(fontSize: 12, color: textSecondary),
                      )
                    else if (_status.usesEmailLinkFallback)
                      Text(
                        _status.hasActiveCode
                            ? 'Verification link sent — check inbox or Spam folder'
                            : 'Tap Resend link below to receive a verification email',
                        style: TextStyle(fontSize: 12, color: textSecondary),
                      )
                    else if (_status.hasActiveCode && expirySec > 0)
                      Text(
                        'Code expires in ${_formatDuration(expirySec)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: expirySec <= 90
                              ? const Color(0xFFD97706)
                              : textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                      )
                    else if (_status.isExpired)
                      const Text(
                        'Previous code expired — request a new one below',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFFD97706),
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else
                      Text(
                        'Code valid for ${_status.ttlMinutes} minutes',
                        style: TextStyle(fontSize: 12, color: textSecondary),
                      ),
                  ],
                ),
              ),
              TextButton(
                key: const Key('toggle_change_email_button'),
                onPressed: _anyInFlight
                    ? null
                    : () => setState(() {
                        _showChangeEmail = !_showChangeEmail;
                        _changeEmailError = null;
                      }),
                style: TextButton.styleFrom(
                  foregroundColor: brand,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                ),
                child: Text(
                  _showChangeEmail ? 'Close' : 'Change',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Inline secure pending email update flow
        if (_showChangeEmail) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: brand.withValues(alpha: isDark ? 0.08 : 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: brand.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Correct your email address',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _status.usesEmailLinkFallback
                      ? 'We will update your unverified account and send a fresh verification link.'
                      : 'We will update your unverified account and send a fresh 6-digit code.',
                  style: TextStyle(fontSize: 12, color: textSecondary),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  key: const Key('change_pending_email_field'),
                  controller: _changeEmailController,
                  enabled: !_anyInFlight,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  style: TextStyle(color: textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'New email address',
                    hintText: 'name@example.com',
                    errorText: _changeEmailError,
                    filled: true,
                    fillColor: inputFill,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _anyInFlight
                          ? null
                          : () => setState(() {
                              _showChangeEmail = false;
                              _changeEmailError = null;
                            }),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      key: const Key('submit_change_pending_email_button'),
                      onPressed: _anyInFlight ? null : _submitChangeEmail,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryFill,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: _isUpdatingEmail
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _status.usesEmailLinkFallback
                                  ? 'Update & Send Link'
                                  : 'Update & Send Code',
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 16),

        // Info / Error feedback banner
        if (_infoMessage != null) ...[
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF0D9488).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: const Color(0xFF0D9488).withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.check_circle_outline_rounded,
                    color: Color(0xFF0D9488),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _infoMessage!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark
                            ? const Color(0xFF5EEAD4)
                            : const Color(0xFF0F766E),
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        if (_errorMessage != null) ...[
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFDC2626).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: const Color(0xFFDC2626).withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Color(0xFFDC2626),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark
                            ? const Color(0xFFFCA5A5)
                            : const Color(0xFFB91C1C),
                        fontWeight: FontWeight.w500,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        if (!_status.usesEmailLinkFallback) ...[
          // 6-digit OTP Input (supports leading zeros, numeric keyboard, paste)
          Semantics(
            label: '6-digit verification code',
            hint: 'Enter the 6-digit numeric code sent to your email',
            textField: true,
            child: TextFormField(
              key: const Key('verification_code_field'),
              controller: _codeController,
              focusNode: _codeFocusNode,
              enabled: !_anyInFlight,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: const [DigitsPasteInputFormatter()],
              maxLength: 6,
              textAlign: TextAlign.center,
              onFieldSubmitted: (_) => _submitVerify(),
              onChanged: (_) {
                if (_inlineCodeError != null) {
                  setState(() => _inlineCodeError = null);
                }
              },
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: 10,
                color: textPrimary,
              ),
              decoration: InputDecoration(
                counterText: '',
                hintText: '• • • • • •',
                hintStyle: TextStyle(
                  fontSize: 20,
                  letterSpacing: 8,
                  color: isDark
                      ? const Color(0xFF475569)
                      : const Color(0xFF94A3B8),
                ),
                errorText: _inlineCodeError,
                filled: true,
                fillColor: inputFill,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
                suffixIcon: IconButton(
                  key: const Key('paste_verification_code_button'),
                  tooltip: 'Paste code from clipboard',
                  onPressed: _anyInFlight ? null : _pasteFromClipboard,
                  icon: Icon(
                    Icons.content_paste_rounded,
                    color: brand,
                    size: 20,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: surfaceBorder, width: 1.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: brand, width: 2),
                ),
                errorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                    color: Color(0xFFDC2626),
                    width: 1.5,
                  ),
                ),
                focusedErrorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(
                    color: Color(0xFFDC2626),
                    width: 2,
                  ),
                ),
              ),
            ),
          ),

          if (_status.attemptsRemaining < 5 &&
              _status.attemptsRemaining > 0) ...[
            const SizedBox(height: 6),
            Text(
              '${_status.attemptsRemaining} verification ${_status.attemptsRemaining == 1 ? 'attempt' : 'attempts'} remaining for this code',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: const Color(0xFFD97706),
              ),
            ),
          ],

          const SizedBox(height: 16),
        ],

        // Verify button
        SizedBox(
          height: 48,
          child: ElevatedButton(
            key: const Key('verify_email_submit_button'),
            onPressed: (_anyInFlight || _isLoadingStatus)
                ? null
                : _submitVerify,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0D9488),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(
                0xFF0D9488,
              ).withValues(alpha: 0.45),
              disabledForegroundColor: Colors.white70,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _isVerifying
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Checking…',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  )
                : Text(
                    _status.usesEmailLinkFallback
                        ? "I've Verified My Email"
                        : 'Verify',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ),

        const SizedBox(height: 10),

        // Resend code / link button with server-driven countdown
        SizedBox(
          height: 46,
          child: OutlinedButton.icon(
            key: const Key('resend_verification_code_button'),
            onPressed: canResend ? _handleResend : null,
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: canResend ? brand : surfaceBorder),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: _isResending
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: brand,
                    ),
                  )
                : Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: canResend ? brand : textSecondary,
                  ),
            label: Text(
              _status.sendLimitReached
                  ? 'Resend limit reached — try later'
                  : cooldownSec > 0
                  ? '${_status.usesEmailLinkFallback ? 'Resend link' : 'Resend code'} (${cooldownSec}s)'
                  : (_status.usesEmailLinkFallback
                        ? 'Resend link'
                        : 'Resend code'),
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: canResend ? brand : textSecondary,
              ),
            ),
          ),
        ),

        const SizedBox(height: 12),

        Text(
          'Check your Spam or Junk folder if the email does not arrive within a minute.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: textSecondary, height: 1.4),
        ),

        const SizedBox(height: 8),

        if (widget.onCancel != null)
          Center(
            child: TextButton(
              onPressed: _anyInFlight ? null : widget.onCancel,
              child: Text(
                'Maybe later',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textSecondary,
                ),
              ),
            ),
          )
        else
          Center(
            child: TextButton.icon(
              key: const Key('verification_sign_out_button'),
              onPressed: _anyInFlight ? null : _handleSignOut,
              icon: Icon(Icons.logout_rounded, size: 16, color: textSecondary),
              label: Text(
                _isSigningOut
                    ? 'Signing out…'
                    : 'Sign out & use another account',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
