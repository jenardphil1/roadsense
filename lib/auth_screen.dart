import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'cloud_service.dart';
import 'app_settings.dart';

/// State-of-the-Art Enterprise Auth Portal for RoadSense GIS & Hazard Platform
class AuthScreen extends StatefulWidget {
  final VoidCallback onAuthSuccess;

  const AuthScreen({super.key, required this.onAuthSuccess});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isSignUp = false;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  String? _errorTitle;
  String? _errorMessage;
  String? _successMessage;

  void _switchAuthMode(bool isSignUp) {
    if (_isSignUp != isSignUp) {
      setState(() {
        _isSignUp = isSignUp;
        _errorTitle = null;
        _errorMessage = null;
        _successMessage = null;
        _formKey.currentState?.reset();
      });
    }
  }

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();

  final MapController _authMapController = MapController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _authMapController.dispose();
    super.dispose();
  }

  // ── Live Map Background ──────────────────────────────────────────────────────

  Widget _buildMapBackground(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        FlutterMap(
          mapController: _authMapController,
          options: MapOptions(
            initialCenter: const LatLng(14.9152, 120.8229),
            initialZoom: 15.5,
            interactionOptions:
                const InteractionOptions(flags: InteractiveFlag.none),
          ),
          children: [
            TileLayer(
              urlTemplate:
                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.pothole_scanner',
              tileDisplay: const TileDisplay.fadeIn(
                duration: Duration(milliseconds: 150),
              ),
            ),
          ],
        ),
        // Legibility scrim over the map
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.30),
                Colors.black.withValues(alpha: 0.38),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Email Verification Dialog ────────────────────────────────────────────────

  /// Shows the email verification dialog (Firebase native link flow).
  /// Automatically sends the verification email first.
  /// Returns true when successfully verified.
  Future<bool> _showEmailVerificationDialog() async {
    int cooldownSeconds = 0;
    int sendAttempts = 0;
    const maxAttempts = 3;
    bool isSubmitting = false;
    String? dialogError;
    Timer? timer;

    void startCooldown(StateSetter setDialogState) {
      cooldownSeconds = 60;
      timer?.cancel();
      timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (cooldownSeconds <= 0) {
          t.cancel();
          setDialogState(() {});
        } else {
          setDialogState(() => cooldownSeconds--);
        }
      });
    }

    // Send the first verification email immediately
    try {
      await CloudService.instance.sendCustomEmailVerificationCode();
      sendAttempts = 1;
    } catch (_) {}

    if (!mounted) return false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            // Start cooldown after first send
            if (sendAttempts == 1 && cooldownSeconds == 0) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                startCooldown(setDialogState);
              });
            }

            String userEmail() => _emailController.text.trim();

            Future<void> verifyViaLink() async {
              setDialogState(() {
                isSubmitting = true;
                dialogError = null;
              });
              final ok = await CloudService.instance.checkNativeEmailVerified();
              setDialogState(() => isSubmitting = false);
              if (ok) {
                timer?.cancel();
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } else {
                setDialogState(() => dialogError =
                    'Not verified yet. Click the link in your email first, then tap the button again.');
              }
            }

            Future<void> resendCode() async {
              if (sendAttempts >= maxAttempts || cooldownSeconds > 0) return;
              setDialogState(() {
                isSubmitting = true;
                dialogError = null;
              });
              sendAttempts++;
              try {
                await CloudService.instance.sendCustomEmailVerificationCode();
                startCooldown(setDialogState);
              } catch (e) {
                setDialogState(() => dialogError = 'Failed to resend code. Please try again.');
              }
              setDialogState(() => isSubmitting = false);
            }

            final isDark = AppSettings.instance.isDarkMode;
            final dialogBg = isDark ? const Color(0xFF131D2E) : Colors.white;
            final boxFill = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
            final boxBorder = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
            final boxText = isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
            final focusColor = isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7);

            return Dialog(
              backgroundColor: dialogBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: BorderSide(color: isDark ? const Color(0xFF1E293B) : Colors.transparent),
              ),
              clipBehavior: Clip.antiAlias,
              insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(28),
                      decoration: const BoxDecoration(
                        color: Color(0xFF0F172A),
                      ),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0284C7).withValues(alpha: 0.2),
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFF0284C7), width: 1.5),
                            ),
                            child: const Icon(
                              Icons.mark_email_read_outlined,
                              color: Color(0xFF38BDF8),
                              size: 30,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Verify Your Email',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'A verification link has been sent to\n${userEmail()}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Body
                    Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        children: [
                          // How-to-verify steps
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: boxFill,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: boxBorder),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Check your inbox',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: boxText,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                _dialogStep('1', 'Open the email we just sent you (check Spam too).'),
                                const SizedBox(height: 8),
                                _dialogStep('2', 'Tap the "Verify email" link inside it.'),
                                const SizedBox(height: 8),
                                _dialogStep('3', 'Come back here and confirm below.'),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),

                          // Error
                          if (dialogError != null)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF7F1D1D).withValues(alpha: 0.3) : const Color(0xFFFEF2F2),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: isDark ? const Color(0xFFDC2626).withValues(alpha: 0.5) : const Color(0xFFFCA5A5)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      dialogError!,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          // Confirm verification button
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0284C7),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 13),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: isSubmitting ? null : () => verifyViaLink(),
                              icon: isSubmitting
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.mark_email_read_rounded, size: 16),
                              label: Text(
                                isSubmitting ? 'Checking…' : "I've Verified My Email ✓",
                                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),

                          const SizedBox(height: 10),

                          // Resend email button
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                side: BorderSide(
                                  color: (sendAttempts >= maxAttempts || cooldownSeconds > 0)
                                      ? (isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1))
                                      : focusColor,
                                ),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: (isSubmitting || cooldownSeconds > 0 || sendAttempts >= maxAttempts)
                                  ? null
                                  : () => resendCode(),
                              icon: Icon(
                                Icons.send_rounded,
                                size: 15,
                                color: (sendAttempts >= maxAttempts || cooldownSeconds > 0)
                                    ? const Color(0xFF94A3B8)
                                    : focusColor,
                              ),
                              label: Text(
                                cooldownSeconds > 0
                                    ? 'Resend Email (${cooldownSeconds}s)'
                                    : sendAttempts >= maxAttempts
                                        ? 'Resend Limit Reached'
                                        : 'Resend Verification Email',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: (sendAttempts >= maxAttempts || cooldownSeconds > 0)
                                      ? const Color(0xFF94A3B8)
                                      : focusColor,
                                ),
                              ),
                            ),
                          ),

                            const SizedBox(height: 12),

                            // Cancel / sign out link
                            TextButton(
                              onPressed: () {
                                timer?.cancel();
                                Navigator.of(ctx).pop(false);
                              },
                              child: Text(
                                'Cancel & Sign Out',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );

    timer?.cancel();

    return result ?? false;
  }

  Widget _dialogStep(String number, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: Color(0xFF0284C7),
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Color(0xFF94A3B8),
            ),
          ),
        ),
      ],
    );
  }

  // ── Submit Logic ─────────────────────────────────────────────────────────────

  Future<void> _submitEmailAuth() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorTitle = null;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      if (_isSignUp) {
        // 1. Create Firebase Auth account
        final fullName = '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}'.trim();
        await CloudService.instance.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
          fullName: fullName.isEmpty ? 'RoadSense User' : fullName,
        );
        if (!mounted) return;
        setState(() => _isLoading = false);

        // 2. Show verification dialog (sends code automatically)
        final verified = await _showEmailVerificationDialog();
        if (!mounted) return;
        if (verified) {
          widget.onAuthSuccess();
        } else {
          // User cancelled — sign them out so they can't proceed without verifying
          await CloudService.instance.signOut();
          if (mounted) {
            setState(() {
              _successMessage = null;
              _errorTitle = 'Email Not Verified';
              _errorMessage = 'Your account was created but email verification is required. Sign in to complete verification.';
              _isSignUp = false;
            });
          }
        }
        return;
      } else {
        // Sign In
        await CloudService.instance.signIn(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
        if (!mounted) return;

        // Check if the user is Google-authenticated (skip code for Google)
        final currentUser = FirebaseAuth.instance.currentUser;
        final isGoogle = currentUser != null &&
            currentUser.providerData.any((p) => p.providerId == 'google.com');

        if (!isGoogle) {
          // Check email verification
          final isVerified = await CloudService.instance.isEmailVerified();
          if (!mounted) return;
          if (!isVerified) {
            setState(() => _isLoading = false);
            // Show verification dialog
            final verified = await _showEmailVerificationDialog();
            if (!mounted) return;
            if (verified) {
              widget.onAuthSuccess();
            } else {
              // Sign out — not verified
              await CloudService.instance.signOut();
              if (mounted) {
                setState(() {
                  _errorTitle = 'Email Not Verified';
                  _errorMessage = 'Please verify your email address to access RoadSense. Sign in again and complete the verification step.';
                });
              }
            }
            return;
          }
        }
      }
      widget.onAuthSuccess();
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        if (e.code == 'email-already-in-use') {
          final registeredEmail = _emailController.text.trim();
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Row(
                children: [
                  Icon(Icons.mark_email_read_rounded, color: Color(0xFFDC2626), size: 24),
                  SizedBox(width: 10),
                  Text('Email Already Registered', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'An official RoadSense account is already registered under this email address:',
                    style: TextStyle(fontSize: 13, color: Color(0xFF475569), height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFCA5A5)),
                    ),
                    child: Text(
                      registeredEmail,
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF991B1B), fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Would you like to switch to Sign In to access your account?',
                    style: TextStyle(fontSize: 13, color: Color(0xFF475569)),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B))),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _switchAuthMode(false);
                  },
                  child: const Text('Switch to Sign In', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
          return;
        }

        String title = 'Incorrect Email or Password';
        String message = 'The email address or password you entered is incorrect. Please check your credentials and try again.';
        if (e.code == 'operation-not-allowed') {
          title = 'Authentication Disabled';
          message = 'Email/Password authentication is disabled in Firebase Console.';
        } else if (e.code == 'invalid-credential' || e.code == 'wrong-password' || e.code == 'user-not-found' || e.code == 'invalid-email') {
          title = 'Incorrect Email or Password';
          message = 'The email address or password you entered is incorrect. Please check your credentials and try again.';
        } else if (e.code == 'weak-password') {
          title = 'Password Security Standard';
          message = 'Password must be at least 8 characters long.';
        } else {
          title = 'Authentication Error';
          message = e.message ?? 'An error occurred during authentication. Please try again.';
        }
        setState(() {
          _errorTitle = title;
          _errorMessage = message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorTitle = 'Incorrect Email or Password';
          _errorMessage = e.toString().replaceAll(RegExp(r'\[.*?\]'), '').trim();
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _checkRedirectResult();
    }
  }

  Future<void> _checkRedirectResult() async {
    try {
      final userCred = await FirebaseAuth.instance.getRedirectResult();
      if (userCred.user != null && mounted) {
        widget.onAuthSuccess();
      }
    } catch (e) {
      print('Redirect result check error: $e');
    }
  }

  Future<void> _submitGoogleAuth() async {
    setState(() {
      _isLoading = true;
      _errorTitle = null;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      final cred = await CloudService.instance.signInWithGoogle();
      if (cred != null) {
        widget.onAuthSuccess();
      }
    } catch (e) {
      if (mounted) {
        String title = 'Google Sign-In Notice';
        String message = 'Unable to complete Google Sign-In. Please try again.';
        if (e is FirebaseAuthException) {
          if (e.code == 'invalid-app-credential' || e.message?.contains('invalid_app_ID') == true) {
            title = 'Google Auth Setup Notice';
            message = 'Native Android Google Sign-In requires linking your app SHA-1 fingerprint in Firebase Console. You can also sign in directly using Email & Password below.';
          } else {
            title = 'Google Auth (${e.code})';
            message = e.message ?? message;
          }
        } else {
          final errStr = e.toString().replaceAll(RegExp(r'\[.*?\]'), '').trim();
          if (errStr.contains('ApiException: 10') || errStr.contains('DEVELOPER_ERROR')) {
            title = 'Google Auth Setup Notice';
            message = 'Native Google Sign-In requires SHA-1 fingerprint registration in Firebase Console. You can sign in using Email & Password or add SHA-1 in Firebase.';
          } else if (errStr.isNotEmpty) {
            message = errStr;
          }
        }
        setState(() {
          _errorTitle = title;
          _errorMessage = message;
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width >= 900;
    final isDark = Theme.of(context).brightness == Brightness.dark || AppSettings.instance.isDarkMode;

    final scaffoldBg = isDark ? const Color(0xFF0B111E) : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF131D2E) : Colors.white;
    final cardBorder = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: isDesktop
          ? SafeArea(
              child: Row(
                children: [
                  // LEFT: Live interactive map pane
                  Expanded(
                    flex: 11,
                    child: _buildSplitMapPane(isDark),
                  ),
                  // Divider
                  Container(width: 1, color: cardBorder),
                  // RIGHT: Registration / sign-in form
                  Expanded(
                    flex: 9,
                    child: _buildAuthPane(isDark, cardBorder),
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                // Live Map Background (mobile / narrow)
                Positioned.fill(child: _buildMapBackground(isDark)),

                SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 28,
                      ),
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 600),
                        curve: Curves.easeInOutCubic,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 460),
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: cardBorder, width: 1.2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: isDark ? 0.35 : 0.06,
                                ),
                                blurRadius: 28,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: _buildAuthForm(isDark),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  // ── Desktop Split Layout ─────────────────────────────────────────────────────

  Widget _buildSplitMapPane(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        FlutterMap(
          mapController: _authMapController,
          options: MapOptions(
            initialCenter: const LatLng(14.9152, 120.8229),
            initialZoom: 14.5,
            minZoom: 5,
            maxZoom: 19,
            interactionOptions: const InteractionOptions(
              flags:
                  InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate:
                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.pothole_scanner',
              tileDisplay: const TileDisplay.fadeIn(
                duration: Duration(milliseconds: 150),
              ),
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: const LatLng(14.9152, 120.8229),
                  width: 40,
                  height: 40,
                  child: Icon(
                    Icons.location_on_rounded,
                    color: Colors.red.shade600,
                    size: 36,
                    shadows: const [
                      Shadow(color: Colors.black38, blurRadius: 6),
                    ],
                  ),
                ),
                const Marker(
                  point: LatLng(14.9452, 120.8629),
                  width: 16,
                  height: 16,
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFF59E0B),
                    size: 18,
                  ),
                ),
                const Marker(
                  point: LatLng(14.8852, 120.7829),
                  width: 16,
                  height: 16,
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFEF4444),
                    size: 18,
                  ),
                ),
              ],
            ),
          ],
        ),

        // Top brand chip
        Positioned(
          top: 20,
          left: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_location_alt_rounded,
                    color: Color(0xFF0284C7), size: 18),
                SizedBox(width: 8),
                Text(
                  'ROADSENSE AI',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Bottom-left tagline chip
        Positioned(
          left: 20,
          bottom: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.travel_explore_rounded,
                    color: Color(0xFF0284C7), size: 15),
                SizedBox(width: 7),
                Text(
                  'Live road hazard map • Drag to explore',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF475569),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Bottom-right zoom hint pill (map is fully draggable/zoomable)
        Positioned(
          right: 20,
          bottom: 20,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mouse_rounded, size: 13, color: Color(0xFF94A3B8)),
                SizedBox(width: 6),
                Text(
                  'Scroll to zoom',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAuthPane(bool isDark, Color cardBorder) {
    final Color paneBg = isDark ? const Color(0xFF131D2E) : Colors.white;
    return Container(
      color: paneBg,
      child: Column(
        children: [
          // Brand accent strip
          Container(
            height: 4,
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0369A1), Color(0xFF0284C7), Color(0xFF22D3EE)],
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: _buildAuthForm(isDark),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthForm(bool isDark) {
    final titleColor = isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
  final switchBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9);
  final inactiveTabTextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final googleBtnBg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final googleBtnBorder = isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);
    final googleBtnText = isDark ? const Color(0xFFF8FAFC) : const Color(0xFF1E293B);
    final dividerColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    final dividerTextColor = isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);
    final inputTextColor = isDark ? const Color(0xFFF8FAFC) : const Color(0xFF0F172A);
    final cursorColor = isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7);
    final iconToggleColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Compact brand mark (visible on mobile where branding panel is hidden)
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0284C7),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.add_location_alt_rounded, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 10),
                Text(
                  'ROADSENSE',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: titleColor,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 22),

            // Header Title
            Text(
              _isSignUp ? 'Create Account' : 'Welcome Back',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: titleColor, height: 1.15),
            ),
            const SizedBox(height: 8),
            Container(
              width: 46,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: const LinearGradient(
                  colors: [Color(0xFF0284C7), Color(0xFF22D3EE)],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _isSignUp
                  ? 'Create your surveyor account to get started.'
                  : 'Sign in to access Live Road Inspection & GIS Analytics',
              style: TextStyle(color: subtitleColor, fontSize: 13, height: 1.45),
            ),

            const SizedBox(height: 16),

            // Quick feature bullets
            Row(
              children: [
                _featureChip(Icons.camera_alt_rounded, 'AI Detection', isDark),
                const SizedBox(width: 8),
                _featureChip(Icons.route_rounded, 'Safe Routing', isDark),
                const SizedBox(width: 8),
                _featureChip(Icons.insights_rounded, 'Live Analytics', isDark),
              ],
            ),

            const SizedBox(height: 18),

            // Segmented Switcher — fixed height, no layout shift
            Container(
              height: 44,
              decoration: BoxDecoration(
                color: switchBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isDark ? const Color(0xFF334155) : Colors.transparent),
              ),
              padding: const EdgeInsets.all(4),
              child: Stack(
                children: [
                  AnimatedAlign(
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeInOutCubic,
                    alignment: _isSignUp ? Alignment.centerRight : Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: 0.5,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF0284C7),
                          borderRadius: BorderRadius.circular(9),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF0284C7).withValues(alpha: 0.35),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _switchAuthMode(false),
                            child: Center(
                              child: Text(
                                'Sign In',
                                style: TextStyle(
                                  fontWeight: !_isSignUp ? FontWeight.bold : FontWeight.w500,
                                  color: !_isSignUp ? Colors.white : inactiveTabTextColor,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _switchAuthMode(true),
                            child: Center(
                              child: Text(
                                'Register',
                                style: TextStyle(
                                  fontWeight: _isSignUp ? FontWeight.bold : FontWeight.w500,
                                  color: _isSignUp ? Colors.white : inactiveTabTextColor,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Official Notification Banners
            if (_errorMessage != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF7F1D1D).withValues(alpha: 0.3) : const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isDark ? const Color(0xFFDC2626).withValues(alpha: 0.5) : const Color(0xFFFCA5A5)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _errorTitle ?? 'Incorrect Email or Password',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _errorMessage!,
                            style: TextStyle(fontSize: 12, color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C), height: 1.35, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => setState(() => _errorMessage = null),
                        child: Icon(Icons.close_rounded, color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B), size: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (_successMessage != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF064E3B).withValues(alpha: 0.3) : const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isDark ? const Color(0xFF059669).withValues(alpha: 0.5) : const Color(0xFFA7F3D0)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle_outline_rounded, color: Color(0xFF0284C7), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Success',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0284C7)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _successMessage!,
                            style: const TextStyle(fontSize: 12, color: Color(0xFF0284C7), height: 1.35, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => setState(() => _successMessage = null),
                        child: const Icon(Icons.close_rounded, color: Color(0xFF0284C7), size: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Google Sign-In Button
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                minimumSize: const Size(double.infinity, 46),
                side: BorderSide(color: googleBtnBorder),
                backgroundColor: googleBtnBg,
                enabledMouseCursor: SystemMouseCursors.click,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _isLoading ? null : _submitGoogleAuth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.network(
                    'https://upload.wikimedia.org/wikipedia/commons/5/53/Google_%22G%22_Logo.svg',
                    height: 18,
                    errorBuilder: (ctx, e, st) => const Icon(Icons.g_mobiledata, size: 24, color: Colors.blue),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Continue with Google',
                    style: TextStyle(fontWeight: FontWeight.w600, color: googleBtnText, fontSize: 13.5),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),

            Row(
              children: [
                Expanded(child: Divider(color: dividerColor)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'OR EMAIL',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: dividerTextColor, letterSpacing: 0.8),
                  ),
                ),
                Expanded(child: Divider(color: dividerColor)),
              ],
            ),

            const SizedBox(height: 18),

            AnimatedSize(
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOutCubic,
              child: _isSignUp
                  ? ClipRect(
                      clipBehavior: Clip.hardEdge,
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      controller: _firstNameController,
                                      cursorColor: cursorColor,
                                      style: TextStyle(color: inputTextColor, fontSize: 14.5, fontWeight: FontWeight.w500),
                                      decoration: _inputDecoration('First Name', Icons.person_outline, isDark: isDark),
                                      validator: (v) => (_isSignUp && (v == null || v.trim().isEmpty)) ? 'Required' : null,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: TextFormField(
                                      controller: _lastNameController,
                                      cursorColor: cursorColor,
                                      style: TextStyle(color: inputTextColor, fontSize: 14.5, fontWeight: FontWeight.w500),
                                      decoration: _inputDecoration('Last Name', Icons.person_outline, isDark: isDark),
                                      validator: (v) => (_isSignUp && (v == null || v.trim().isEmpty)) ? 'Required' : null,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                            ],
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),

            // Email
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              cursorColor: cursorColor,
              style: TextStyle(color: inputTextColor, fontSize: 14.5, fontWeight: FontWeight.w500),
              decoration: _inputDecoration('Email Address', Icons.email_outlined, isDark: isDark),
              validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email address' : null,
            ),

            const SizedBox(height: 14),

            // Password
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              cursorColor: cursorColor,
              style: TextStyle(color: inputTextColor, fontSize: 14.5, fontWeight: FontWeight.w500),
              decoration: _inputDecoration(
                'Password',
                Icons.lock_outline_rounded,
                isDark: isDark,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    color: iconToggleColor,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Please enter a password';
                if (_isSignUp && v.length < 8) return 'Password must be at least 8 characters long';
                return null;
              },
              onChanged: (_) {
                if (_isSignUp) setState(() {});
              },
            ),

            // Live password strength meter (sign-up only)
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: _isSignUp && _passwordController.text.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _passwordStrengthMeter(isDark, subtitleColor),
                    )
                  : const SizedBox.shrink(),
            ),

            AnimatedSize(
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOutCubic,
              child: _isSignUp
                  ? ClipRect(
                      clipBehavior: Clip.hardEdge,
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 5),
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Text(
                                  'Security Standard: Minimum of 8 characters.',
                                  style: TextStyle(fontSize: 11, color: subtitleColor, fontWeight: FontWeight.w500),
                                ),
                              ),
                              const SizedBox(height: 14),
                              // Confirm Password
                              TextFormField(
                                controller: _confirmPasswordController,
                                obscureText: _obscureConfirmPassword,
                                cursorColor: cursorColor,
                                style: TextStyle(color: inputTextColor, fontSize: 14.5, fontWeight: FontWeight.w500),
                                decoration: _inputDecoration(
                                  'Confirm Password',
                                  Icons.lock_reset_rounded,
                                  isDark: isDark,
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureConfirmPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                      color: iconToggleColor,
                                      size: 20,
                                    ),
                                    onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                                  ),
                                ),
                                validator: (v) {
                                  if (!_isSignUp) return null;
                                  if (v == null || v.isEmpty) return 'Please confirm your password';
                                  if (v != _passwordController.text) return 'Passwords do not match';
                                  return null;
                                },
                              ),
                              const SizedBox(height: 14),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                                decoration: BoxDecoration(
                                  color: isDark ? const Color(0xFF0C4A6E).withValues(alpha: 0.25) : const Color(0xFFECFDF5),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: isDark ? const Color(0xFF0284C7).withValues(alpha: 0.4) : const Color(0xFFA7F3D0)),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(Icons.mark_email_read_outlined, color: Color(0xFF0284C7), size: 18),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        'A verification link will be sent to your email address immediately after registration.',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                                          height: 1.4,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),

            const SizedBox(height: 20),

            // Submit Button — brand gradient with glow
            SizedBox(
              width: double.infinity,
              height: 50,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF0369A1), Color(0xFF0284C7), Color(0xFF0891B2)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0284C7).withValues(alpha: _isLoading ? 0.0 : 0.35),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    disabledForegroundColor: Colors.white70,
                    disabledBackgroundColor: Colors.transparent,
                    enabledMouseCursor: SystemMouseCursors.click,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _isLoading ? null : _submitEmailAuth,
                  child: _isLoading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Text(
                          _isSignUp ? 'Create Account & Verify Email' : 'Sign In to Portal',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5, letterSpacing: 0.2),
                        ),
                ),
              ),
            ),

            const SizedBox(height: 14),

            // Trust footer
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline_rounded, size: 12, color: subtitleColor),
                const SizedBox(width: 5),
                Text(
                  'Protected by Firebase Authentication',
                  style: TextStyle(fontSize: 11, color: subtitleColor, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _featureChip(IconData icon, String label, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0C4A6E).withValues(alpha: 0.3) : const Color(0xFFF0F9FF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? const Color(0xFF0284C7).withValues(alpha: 0.4) : const Color(0xFFBAE6FD)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: const Color(0xFF0284C7)),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: isDark ? const Color(0xFF7DD3FC) : const Color(0xFF0369A1),
            ),
          ),
        ],
      ),
    );
  }

  int _passwordStrengthScore(String v) {
    int score = 0;
    if (v.length >= 8) score++;
    if (v.length >= 12) score++;
    if (RegExp(r'[A-Z]').hasMatch(v) && RegExp(r'[0-9]').hasMatch(v)) score++;
    return score.clamp(1, 3);
  }

  Widget _passwordStrengthMeter(bool isDark, Color subtitleColor) {
    final int score = _passwordStrengthScore(_passwordController.text);
    final Color barColor = score == 1
        ? const Color(0xFFEF4444)
        : score == 2
            ? const Color(0xFFF59E0B)
            : const Color(0xFF10B981);
    final String label = score == 1 ? 'Weak' : score == 2 ? 'Fair' : 'Strong';
    return Row(
      children: [
        Expanded(
          child: Row(
            children: List.generate(3, (i) {
              return Expanded(
                child: Container(
                  height: 4,
                  margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                  decoration: BoxDecoration(
                    color: i < score ? barColor : (isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: barColor),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon, {Widget? suffixIcon, bool isDark = false}) {
    final borderCol = isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);
    final enabledBorderCol = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final focusCol = isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7);
    final fillCol = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final labelCol = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: labelCol, fontSize: 13),
      floatingLabelStyle: TextStyle(color: focusCol, fontSize: 12, fontWeight: FontWeight.w600),
      floatingLabelBehavior: FloatingLabelBehavior.auto,
      prefixIcon: Icon(icon, color: labelCol, size: 20),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: fillCol,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderCol)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: enabledBorderCol)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: focusCol, width: 1.8)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFEF4444))),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }
}

/// Custom painter for rendering subtle technical background grid lines
class TechGridPainter extends CustomPainter {
  final bool isDark;
  TechGridPainter({this.isDark = false});

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = (isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1))
          .withValues(alpha: isDark ? 0.22 : 0.35)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant TechGridPainter oldDelegate) =>
      oldDelegate.isDark != isDark;
}

