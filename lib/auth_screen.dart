import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'cloud_service.dart';
import 'app_settings.dart';
import 'app_design.dart';
import 'mobile_components.dart';
import 'email_verification_client.dart';
import 'email_verification_view.dart';

/// State-of-the-Art Enterprise Auth Portal for RoadSense GIS & Hazard Platform
class AuthScreen extends StatefulWidget {
  final VoidCallback onAuthSuccess;
  final User? pendingVerificationUser;
  final String? initialPendingVerificationEmail;
  final EmailVerificationBackend? verificationBackend;

  const AuthScreen({
    super.key,
    required this.onAuthSuccess,
    this.pendingVerificationUser,
    this.initialPendingVerificationEmail,
    this.verificationBackend,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with TickerProviderStateMixin {
  bool _isSignUp = false;
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _rememberMe = true;
  bool _isMapExploreMode = false;
  bool _showVerificationView = false;
  EmailVerificationStatus? _verificationInitialStatus;
  String? _verificationInitialError;
  String? _verificationInitialInfo;
  bool _verificationFetchStatusOnMount = true;
  bool _verificationAutoSendIfMissing = false;
  String? _errorTitle;
  String? _errorMessage;
  String? _successMessage;

  late final AnimationController _modeController;
  late final Animation<double> _modeAnimation;
  late final AnimationController _radarController;
  late final AnimationController _entranceController;
  late final Animation<double> _entranceFade;
  late final Animation<Offset> _entranceSlide;

  @override
  void initState() {
    super.initState();
    _modeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _modeAnimation = CurvedAnimation(
      parent: _modeController,
      curve: Curves.easeInOutCubic,
    );
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _entranceFade = CurvedAnimation(
      parent: _entranceController,
      curve: const Interval(0.0, 0.85, curve: Curves.easeOutCubic),
    );
    _entranceSlide =
        Tween<Offset>(begin: const Offset(0.0, 0.06), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: Curves.easeOutCubic,
          ),
        );
    _entranceController.forward();
    if (widget.pendingVerificationUser != null ||
        widget.initialPendingVerificationEmail != null) {
      _showVerificationView = true;
      _verificationFetchStatusOnMount = true;
      _verificationAutoSendIfMissing = false;
    }
    if (kIsWeb) {
      _checkRedirectResult();
    }
  }

  @override
  void didUpdateWidget(covariant AuthScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isLoading) return;
    if (widget.pendingVerificationUser != null &&
        (oldWidget.pendingVerificationUser?.uid !=
                widget.pendingVerificationUser?.uid ||
            !_showVerificationView)) {
      setState(() {
        _isMapExploreMode = false;
        _showVerificationView = true;
        _verificationInitialStatus = null;
        _verificationInitialError = null;
        _verificationInitialInfo = null;
        _verificationFetchStatusOnMount = true;
        _verificationAutoSendIfMissing = false;
      });
    } else if (widget.pendingVerificationUser == null &&
        oldWidget.pendingVerificationUser != null &&
        _showVerificationView) {
      setState(() {
        _showVerificationView = false;
      });
    }
  }

  void _switchAuthMode(bool isSignUp) {
    if (_isSignUp != isSignUp) {
      setState(() {
        _isSignUp = isSignUp;
        _errorTitle = null;
        _errorMessage = null;
        _successMessage = null;
        _formKey.currentState?.reset();
      });
      if (isSignUp) {
        _modeController.forward();
      } else {
        _modeController.reverse();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _radarController.stop();
    } else if (!_radarController.isAnimating) {
      _radarController.repeat();
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
    _modeController.dispose();
    _radarController.dispose();
    _entranceController.dispose();
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
            initialZoom: 14.5,
            minZoom: 5,
            maxZoom: 19,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.pothole_scanner',
              tileDisplay: const TileDisplay.fadeIn(
                duration: Duration(milliseconds: 150),
              ),
            ),
            const MarkerLayer(markers: []),
          ],
        ),
        // Legibility scrim over the map (IgnorePointer ensures touches reach map)
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? [
                        Colors.black.withValues(alpha: 0.35),
                        Colors.black.withValues(alpha: 0.50),
                      ]
                    : [
                        Colors.black.withValues(alpha: 0.18),
                        Colors.black.withValues(alpha: 0.32),
                      ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Password Reset Dialog ────────────────────────────────────────────────────

  /// Displays the password reset dialog and triggers Firebase password reset email.
  Future<void> _showForgotPasswordDialog() async {
    final resetEmailController = TextEditingController(
      text: _emailController.text.trim(),
    );
    bool isSending = false;
    String? dialogMsg;
    bool isError = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isDark =
              Theme.of(ctx).brightness == Brightness.dark ||
              AppSettings.instance.isDarkMode;
          final dialogBg = isDark ? const Color(0xFF131D2E) : Colors.white;
          final textColor = isDark
              ? const Color(0xFFF8FAFC)
              : const Color(0xFF0F172A);
          final subColor = isDark
              ? const Color(0xFF94A3B8)
              : const Color(0xFF64748B);

          return AlertDialog(
            backgroundColor: dialogBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppDesign.brandWash(isDark),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.lock_reset_rounded,
                    color: AppDesign.accent(isDark),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Reset Password',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enter your registered email address to receive password recovery instructions.',
                    style: TextStyle(
                      fontSize: 13,
                      color: subColor,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: resetEmailController,
                    keyboardType: TextInputType.emailAddress,
                    style: TextStyle(color: textColor, fontSize: 14),
                    decoration: _inputDecoration(
                      'Email Address',
                      Icons.email_outlined,
                      isDark: isDark,
                    ),
                  ),
                  if (dialogMsg != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      dialogMsg!,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: isError
                            ? const Color(0xFFEF4444)
                            : const Color(0xFF10B981),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('Cancel', style: TextStyle(color: subColor)),
              ),
              ElevatedButton(
                style: AppDesign.primaryButtonStyle(isDark: isDark),
                onPressed: isSending
                    ? null
                    : () async {
                        final email = resetEmailController.text.trim();
                        if (email.isEmpty || !email.contains('@')) {
                          setDialogState(() {
                            dialogMsg = 'Please enter a valid email address.';
                            isError = true;
                          });
                          return;
                        }
                        setDialogState(() {
                          isSending = true;
                          dialogMsg = null;
                        });
                        try {
                          await FirebaseAuth.instance.sendPasswordResetEmail(
                            email: email,
                          );
                          setDialogState(() {
                            isSending = false;
                            dialogMsg =
                                'Password reset email sent! Check your inbox.';
                            isError = false;
                          });
                        } catch (e) {
                          setDialogState(() {
                            isSending = false;
                            dialogMsg = e
                                .toString()
                                .replaceAll(RegExp(r'\[.*?\]'), '')
                                .trim();
                            isError = true;
                          });
                        }
                      },
                child: isSending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text('Send Reset Link'),
              ),
            ],
          );
        },
      ),
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
        // 1. Create Firebase Auth account and send verification link, then let
        //    the user enter the site immediately (verification is required when
        //    submitting pothole reports).
        final fullName =
            '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}'
                .trim();
        await CloudService.instance.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          fullName: fullName.isEmpty ? 'RoadSense User' : fullName,
        );
        if (!mounted) return;
        setState(() => _isLoading = false);
      } else {
        // Sign In
        await CloudService.instance.signIn(
          rememberMe: _rememberMe,
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
        if (!mounted) return;
      }
      widget.onAuthSuccess();
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        if (e.code == 'email-already-in-use') {
          final registeredEmail = _emailController.text.trim();
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Row(
                children: [
                  Icon(
                    Icons.mark_email_read_rounded,
                    color: Color(0xFFDC2626),
                    size: 24,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Email Already Registered',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'An official RoadSense account is already registered under this email address:',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF475569),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFCA5A5)),
                    ),
                    child: Text(
                      registeredEmail,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF991B1B),
                        fontSize: 13,
                      ),
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
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Color(0xFF64748B)),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppDesign.brand,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _switchAuthMode(false);
                  },
                  child: const Text(
                    'Switch to Sign In',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          );
          return;
        }

        String title = 'Incorrect Email or Password';
        String message =
            'The email address or password you entered is incorrect. Please check your credentials and try again.';
        if (e.code == 'operation-not-allowed') {
          title = 'Authentication Disabled';
          message =
              'Email/Password authentication is disabled in Firebase Console.';
        } else if (e.code == 'invalid-credential' ||
            e.code == 'wrong-password' ||
            e.code == 'user-not-found' ||
            e.code == 'invalid-email') {
          title = 'Incorrect Email or Password';
          message =
              'The email address or password you entered is incorrect. Please check your credentials and try again.';
        } else if (e.code == 'weak-password') {
          title = 'Password Security Standard';
          message = 'Password must be at least 8 characters long.';
        } else {
          title = 'Authentication Error';
          message =
              e.message ??
              'An error occurred during authentication. Please try again.';
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
          _errorMessage = e
              .toString()
              .replaceAll(RegExp(r'\[.*?\]'), '')
              .trim();
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _checkRedirectResult() async {
    try {
      final userCred = await FirebaseAuth.instance.getRedirectResult();
      if (userCred.user != null && mounted) {
        widget.onAuthSuccess();
      }
    } catch (e) {
      debugPrint('Redirect result check error: $e');
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
      final cred = await CloudService.instance.signInWithGoogle(
        rememberMe: _rememberMe,
      );
      if (cred != null) {
        widget.onAuthSuccess();
      }
    } catch (e) {
      if (mounted) {
        String title = 'Google Sign-In Notice';
        String message = 'Unable to complete Google Sign-In. Please try again.';
        if (e is FirebaseAuthException) {
          if (e.code == 'invalid-app-credential' ||
              e.message?.contains('invalid_app_ID') == true) {
            title = 'Google Auth Setup Notice';
            message =
                'Native Android Google Sign-In requires linking your app SHA-1 fingerprint in Firebase Console. You can also sign in directly using Email & Password below.';
          } else {
            title = 'Google Auth (${e.code})';
            message = e.message ?? message;
          }
        } else {
          final errStr = e.toString().replaceAll(RegExp(r'\[.*?\]'), '').trim();
          if (errStr.contains('ApiException: 10') ||
              errStr.contains('DEVELOPER_ERROR')) {
            title = 'Google Auth Setup Notice';
            message =
                'Add your SHA-1 fingerprint (0B:75:69:C4:D4:1E:7E:E8:BE:C1:83:15:D8:2C:16:91:31:DA:AC:5B) in Firebase Console, or sign in using Email & Password.';
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
    final isDark =
        Theme.of(context).brightness == Brightness.dark ||
        AppSettings.instance.isDarkMode;

    final scaffoldBg = isDark
        ? const Color(0xFF0B111E)
        : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF131D2E) : Colors.white;
    final cardBorder = isDark
        ? const Color(0xFF1E293B)
        : const Color(0xFFE2E8F0);

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: isDesktop
          ? SafeArea(
              child: Row(
                children: [
                  // LEFT: Live interactive map pane
                  Expanded(flex: 11, child: _buildSplitMapPane(isDark)),
                  // Divider
                  Container(width: 1, color: cardBorder),
                  // RIGHT: Registration / sign-in form
                  Expanded(flex: 9, child: _buildAuthPane(isDark, cardBorder)),
                ],
              ),
            )
          : Stack(
              children: [
                // Live Map Background (mobile / narrow)
                Positioned.fill(child: _buildMapBackground(isDark)),

                // Floating Map Navigation Buttons (Zoom & Recenter)
                Positioned(
                  right: 16,
                  bottom: _isMapExploreMode ? 84 : 20,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildAuthMapButton(
                        icon: Icons.add_rounded,
                        tooltip: 'Zoom in',
                        isDark: isDark,
                        onTap: () {
                          try {
                            final c = _authMapController.camera.center;
                            final z = (_authMapController.camera.zoom + 1)
                                .clamp(5.0, 19.0);
                            _authMapController.move(c, z);
                          } catch (_) {}
                        },
                      ),
                      const SizedBox(height: 8),
                      _buildAuthMapButton(
                        icon: Icons.remove_rounded,
                        tooltip: 'Zoom out',
                        isDark: isDark,
                        onTap: () {
                          try {
                            final c = _authMapController.camera.center;
                            final z = (_authMapController.camera.zoom - 1)
                                .clamp(5.0, 19.0);
                            _authMapController.move(c, z);
                          } catch (_) {}
                        },
                      ),
                      const SizedBox(height: 8),
                      _buildAuthMapButton(
                        icon: Icons.my_location_rounded,
                        tooltip: 'Recenter Sector Bulacan',
                        isDark: isDark,
                        onTap: () {
                          try {
                            _authMapController.move(
                              const LatLng(14.9152, 120.8229),
                              14.5,
                            );
                          } catch (_) {}
                        },
                      ),
                    ],
                  ),
                ),

                // Auth Card (collapsible when exploring map, always shown for email verification)
                if (!_isMapExploreMode || _showVerificationView)
                  SafeArea(
                    child: Center(
                      child: Builder(
                        builder: (context) {
                          final size = MediaQuery.sizeOf(context);
                          final bool isPhoneLandscape =
                              size.width > size.height && size.height < 560;
                          return SingleChildScrollView(
                            padding: EdgeInsets.symmetric(
                              horizontal: isPhoneLandscape ? 16 : 20,
                              vertical: isPhoneLandscape ? 12 : 28,
                            ),
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth: isPhoneLandscape ? 520 : 460,
                              ),
                              decoration: BoxDecoration(
                                color: cardBg.withValues(
                                  alpha: isDark ? 0.90 : 0.94,
                                ),
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(
                                  color: cardBorder,
                                  width: 1.2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: isDark ? 0.35 : 0.08,
                                    ),
                                    blurRadius: 32,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(24),
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(
                                    sigmaX: 16,
                                    sigmaY: 16,
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.all(
                                      isPhoneLandscape ? 16 : 28,
                                    ),
                                    child: _buildAuthForm(isDark),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  )
                else
                  // Bottom pill to easily bring back the sign in form
                  Positioned(
                    left: 20,
                    right: 80,
                    bottom: 20,
                    child: SafeArea(
                      child: Center(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            setState(() => _isMapExploreMode = false);
                          },
                          icon: const Icon(Icons.login_rounded, size: 18),
                          label: const Text('Back to Sign In'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppDesign.brand,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 6,
                          ),
                        ),
                      ),
                    ),
                  ),

                // Map Explore Button (rendered above the card so it is never obscured)
                if (!_isMapExploreMode && !_showVerificationView)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: SafeArea(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () {
                            setState(() => _isMapExploreMode = true);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: cardBg.withValues(alpha: 0.94),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: cardBorder),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black26,
                                  blurRadius: 10,
                                  offset: Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.explore_rounded,
                                  size: 16,
                                  color: AppDesign.accent(isDark),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Explore Map',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: isDark
                                        ? Colors.white
                                        : const Color(0xFF0F172A),
                                  ),
                                ),
                              ],
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
    final chipBg = isDark
        ? const Color(0xFF0F172A).withValues(alpha: 0.85)
        : Colors.white.withValues(alpha: 0.90);
    final chipBorder = isDark
        ? const Color(0xFF334155).withValues(alpha: 0.7)
        : const Color(0xFFE2E8F0);
    final primaryText = isDark
        ? const Color(0xFFF8FAFC)
        : const Color(0xFF0F172A);
    final secondaryText = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);

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
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.pothole_scanner',
              tileDisplay: const TileDisplay.fadeIn(
                duration: Duration(milliseconds: 150),
              ),
            ),
            const MarkerLayer(markers: []),
          ],
        ),

        // Vignette Scrim Overlay for contrast and atmosphere
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? [
                          const Color(0xFF0B111E).withValues(alpha: 0.55),
                          const Color(0xFF0B111E).withValues(alpha: 0.20),
                          const Color(0xFF0B111E).withValues(alpha: 0.70),
                        ]
                      : [
                          Colors.black.withValues(alpha: 0.20),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.35),
                        ],
                ),
              ),
            ),
          ),
        ),

        // Top brand HUD pill
        Positioned(
          top: 24,
          left: 24,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: chipBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: chipBorder),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.35 : 0.08,
                      ),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: RoadSenseLogo(
                  size: 28,
                  showWordmark: true,
                  subtitle: 'Live Mesh Active',
                  isDarkOverride: isDark,
                ),
              ),
            ),
          ),
        ),

        // Bottom-left Telemetry HUD card
        Positioned(
          left: 24,
          bottom: 24,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                width: 320,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: chipBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: chipBorder),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.40 : 0.10,
                      ),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.sensors_rounded,
                              color: AppDesign.accent(isDark),
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'SECTOR BULACAN',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                                color: primaryText,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppDesign.brandWash(isDark),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: AppDesign.brandBorder(isDark),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            'DPWH STD',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                              color: AppDesign.accent(isDark),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _telemetryMetric(
                          'HAZARDS',
                          'Sign in to view',
                          const Color(0xFFEF4444),
                          isDark,
                        ),
                        const SizedBox(width: 8),
                        _telemetryMetric(
                          'AI ENGINE',
                          'YOLOv8',
                          AppDesign.accent(isDark),
                          isDark,
                        ),
                        const SizedBox(width: 8),
                        _telemetryMetric(
                          'LATENCY',
                          '—',
                          const Color(0xFF10B981),
                          isDark,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Interactive GIS Surface • Pan & Zoom freely',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Right-side floating zoom & recenter controls for desktop
        Positioned(
          right: 20,
          bottom: 24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildAuthMapButton(
                icon: Icons.add_rounded,
                tooltip: 'Zoom in',
                isDark: isDark,
                onTap: () {
                  try {
                    final c = _authMapController.camera.center;
                    final z = (_authMapController.camera.zoom + 1).clamp(
                      5.0,
                      19.0,
                    );
                    _authMapController.move(c, z);
                  } catch (_) {}
                },
              ),
              const SizedBox(height: 8),
              _buildAuthMapButton(
                icon: Icons.remove_rounded,
                tooltip: 'Zoom out',
                isDark: isDark,
                onTap: () {
                  try {
                    final c = _authMapController.camera.center;
                    final z = (_authMapController.camera.zoom - 1).clamp(
                      5.0,
                      19.0,
                    );
                    _authMapController.move(c, z);
                  } catch (_) {}
                },
              ),
              const SizedBox(height: 8),
              _buildAuthMapButton(
                icon: Icons.my_location_rounded,
                tooltip: 'Recenter Sector Bulacan',
                isDark: isDark,
                onTap: () {
                  try {
                    _authMapController.move(
                      const LatLng(14.9152, 120.8229),
                      14.5,
                    );
                  } catch (_) {}
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAuthMapButton({
    required IconData icon,
    required String tooltip,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final btnBg = isDark
        ? const Color(0xFF0F172A).withValues(alpha: 0.90)
        : Colors.white.withValues(alpha: 0.92);
    final btnBorder = isDark
        ? const Color(0xFF334155)
        : const Color(0xFFE2E8F0);
    final iconColor = isDark
        ? const Color(0xFFF8FAFC)
        : const Color(0xFF0F172A);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: btnBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: btnBorder),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
        ),
      ),
    );
  }

  Widget _telemetryMetric(
    String label,
    String value,
    Color accent,
    bool isDark,
  ) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF1E293B).withValues(alpha: 0.6)
              : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                color: isDark
                    ? const Color(0xFF94A3B8)
                    : const Color(0xFF64748B),
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: accent,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthPane(bool isDark, Color cardBorder) {
    final isDesktop = MediaQuery.of(context).size.width >= 900;
    return Stack(
      children: [
        // Ambient radial illumination for background depth
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.85, -0.65),
                radius: 1.15,
                colors: isDark
                    ? [
                        AppDesign.brand.withValues(alpha: 0.16),
                        AppDesign.bg(true),
                      ]
                    : [const Color(0xFFEFF6FF), AppDesign.bg(false)],
              ),
            ),
          ),
        ),

        // Technical CAD grid overlay
        Positioned.fill(
          child: Opacity(
            opacity: isDark ? 0.35 : 0.20,
            child: CustomPaint(painter: TechGridPainter(isDark: isDark)),
          ),
        ),

        // Brand top accent gradient strip
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            height: 4,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF1D4ED8),
                  AppDesign.brand,
                  AppDesign.accent(isDark),
                ],
              ),
            ),
          ),
        ),

        // Center elevated card with entrance animation
        Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isDesktop ? 44 : 16,
              vertical: isDesktop ? 32 : 16,
            ),
            child: FadeTransition(
              opacity: _entranceFade,
              child: SlideTransition(
                position: _entranceSlide,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 480),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF131D2E).withValues(alpha: 0.90)
                        : Colors.white.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF334155).withValues(alpha: 0.8)
                          : const Color(0xFFE2E8F0),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.45 : 0.08,
                        ),
                        blurRadius: 36,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: isDesktop ? 32 : 20,
                          vertical: isDesktop ? 34 : 24,
                        ),
                        child: _buildAuthForm(isDark),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPendingVerificationCard(bool isDark) {
    final activeUser =
        widget.pendingVerificationUser ??
        (Firebase.apps.isNotEmpty ? FirebaseAuth.instance.currentUser : null);
    final initialEmail =
        activeUser?.email ??
        widget.initialPendingVerificationEmail ??
        (_emailController.text.trim().isNotEmpty
            ? _emailController.text.trim()
            : 'your email');
    final backend =
        widget.verificationBackend ??
        CloudService.instance.emailVerificationBackend;

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: EmailVerificationView(
        backend: backend,
        initialEmail: initialEmail,
        initialStatus: _verificationInitialStatus,
        initialError: _verificationInitialError,
        initialInfo: _verificationInitialInfo,
        fetchStatusOnMount: _verificationFetchStatusOnMount,
        autoSendIfMissing: _verificationAutoSendIfMissing,
        isDark: isDark,
        onVerified: () {
          if (!mounted) return;
          setState(() => _showVerificationView = false);
          widget.onAuthSuccess();
        },
        onSignOut: () async {
          await backend.signOut();
          if (!mounted) return;
          setState(() {
            _showVerificationView = false;
            _isSignUp = false;
            _errorTitle = null;
            _errorMessage = null;
            _successMessage =
                'Signed out. Sign in again anytime to finish verifying your email.';
          });
        },
      ),
    );
  }

  Widget _buildAuthForm(bool isDark) {
    if (_showVerificationView) {
      return _buildPendingVerificationCard(isDark);
    }
    final titleColor = isDark
        ? const Color(0xFFF8FAFC)
        : const Color(0xFF0F172A);
    final subtitleColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);
    final switchBg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9);
    final inactiveTabTextColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);
    final googleBtnBg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final googleBtnBorder = isDark
        ? const Color(0xFF334155)
        : const Color(0xFFCBD5E1);
    final googleBtnText = isDark
        ? const Color(0xFFF8FAFC)
        : const Color(0xFF1E293B);
    final dividerColor = isDark
        ? const Color(0xFF334155)
        : const Color(0xFFE2E8F0);
    final dividerTextColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);
    final inputTextColor = isDark
        ? const Color(0xFFF8FAFC)
        : const Color(0xFF0F172A);
    final cursorColor = AppDesign.accent(isDark);
    final iconToggleColor = isDark
        ? const Color(0xFF94A3B8)
        : const Color(0xFF64748B);

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Brand header adapts to enlarged text.
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                RoadSenseLogo(
                  size: 34,
                  showWordmark: true,
                  subtitle: 'Road Condition Platform',
                  isDarkOverride: isDark,
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppDesign.sunken(isDark),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppDesign.border(isDark)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PulsingLiveDot(animation: _radarController),
                      const SizedBox(width: 6),
                      Text(
                        'SECURE',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          color: AppDesign.accent(isDark),
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            SizedBox(
              height:
                  (MediaQuery.sizeOf(context).width >
                          MediaQuery.sizeOf(context).height &&
                      MediaQuery.sizeOf(context).height < 560)
                  ? 10
                  : 22,
            ),

            // Header Title with smooth transition
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.0, 0.12),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: Text(
                _isSignUp ? 'Create Account' : 'Welcome Back',
                key: ValueKey<bool>(_isSignUp),
                style: TextStyle(
                  fontSize:
                      (MediaQuery.sizeOf(context).width >
                              MediaQuery.sizeOf(context).height &&
                          MediaQuery.sizeOf(context).height < 560)
                      ? 21
                      : 26,
                  fontWeight: FontWeight.w800,
                  color: titleColor,
                  height: 1.15,
                ),
              ),
            ),
            if (!(MediaQuery.sizeOf(context).width >
                    MediaQuery.sizeOf(context).height &&
                MediaQuery.sizeOf(context).height < 560)) ...[
              const SizedBox(height: 8),
              Container(
                width: 46,
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: LinearGradient(
                    colors: [AppDesign.brand, AppDesign.accent(isDark)],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Text(
                  _isSignUp
                      ? 'Create your surveyor account to get started.'
                      : 'Sign in to access Live Road Inspection & GIS Analytics',
                  key: ValueKey<bool>(_isSignUp),
                  style: TextStyle(
                    color: subtitleColor,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Quick feature bullets
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _featureChip(Icons.camera_alt_rounded, 'AI Detection', isDark),
                  _featureChip(Icons.route_rounded, 'Safe Routing', isDark),
                  _featureChip(
                    Icons.insights_rounded,
                    'Live Analytics',
                    isDark,
                  ),
                ],
              ),
            ],

            SizedBox(
              height:
                  (MediaQuery.sizeOf(context).width >
                          MediaQuery.sizeOf(context).height &&
                      MediaQuery.sizeOf(context).height < 560)
                  ? 12
                  : 18,
            ),

            // Segmented Switcher — fluid hardware-accelerated animated slider
            Container(
              height: 46,
              decoration: BoxDecoration(
                color: switchBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                ),
              ),
              padding: const EdgeInsets.all(4),
              child: AnimatedBuilder(
                animation: _modeAnimation,
                builder: (context, _) {
                  final t = _modeAnimation.value;
                  final align = Alignment.lerp(
                    Alignment.centerLeft,
                    Alignment.centerRight,
                    t,
                  )!;
                  final signInColor = Color.lerp(
                    Colors.white,
                    inactiveTabTextColor,
                    t,
                  )!;
                  final registerColor = Color.lerp(
                    inactiveTabTextColor,
                    Colors.white,
                    t,
                  )!;

                  return Stack(
                    children: [
                      Align(
                        alignment: align,
                        child: FractionallySizedBox(
                          widthFactor: 0.5,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF1D4ED8), AppDesign.brand],
                              ),
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                BoxShadow(
                                  color: AppDesign.brand.withValues(
                                    alpha: 0.28,
                                  ),
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
                              child: InkWell(
                                onTap: () => _switchAuthMode(false),
                                child: Center(
                                  child: Text(
                                    'Sign In',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: signInColor,
                                      fontSize: 13.5,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: InkWell(
                                onTap: () => _switchAuthMode(true),
                                child: Center(
                                  child: Text(
                                    'Register',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: registerColor,
                                      fontSize: 13.5,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),

            // Official Notification Banners
            if (_errorMessage != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF7F1D1D).withValues(alpha: 0.3)
                      : const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFFDC2626).withValues(alpha: 0.5)
                        : const Color(0xFFFCA5A5),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: Color(0xFFDC2626),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _errorTitle ?? 'Incorrect Email or Password',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? const Color(0xFFFCA5A5)
                                  : const Color(0xFF991B1B),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _errorMessage!,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? const Color(0xFFFCA5A5)
                                  : const Color(0xFFB91C1C),
                              height: 1.35,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => setState(() => _errorMessage = null),
                        child: Icon(
                          Icons.close_rounded,
                          color: isDark
                              ? const Color(0xFFFCA5A5)
                              : const Color(0xFF991B1B),
                          size: 18,
                        ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF064E3B).withValues(alpha: 0.3)
                      : const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF059669).withValues(alpha: 0.5)
                        : const Color(0xFFA7F3D0),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      color: isDark
                          ? const Color(0xFF34D399)
                          : const Color(0xFF047857),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Success',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? const Color(0xFF34D399)
                                  : const Color(0xFF047857),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _successMessage!,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? const Color(0xFFA7F3D0)
                                  : const Color(0xFF065F46),
                              height: 1.35,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => setState(() => _successMessage = null),
                        child: Icon(
                          Icons.close_rounded,
                          color: isDark
                              ? const Color(0xFF34D399)
                              : const Color(0xFF047857),
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Google Sign-In Button with vector logo
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 16,
                ),
                minimumSize: const Size(double.infinity, 48),
                side: BorderSide(color: googleBtnBorder),
                backgroundColor: googleBtnBg,
                enabledMouseCursor: SystemMouseCursors.click,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _isLoading ? null : _submitGoogleAuth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const GoogleGLogo(size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Continue with Google',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: googleBtnText,
                        fontSize: 13.5,
                      ),
                    ),
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
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: dividerTextColor,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                Expanded(child: Divider(color: dividerColor)),
              ],
            ),

            const SizedBox(height: 18),

            // First & Last Name fields animated via SizeTransition + FadeTransition
            SizeTransition(
              sizeFactor: _modeAnimation,
              alignment: Alignment.topCenter,
              child: FadeTransition(
                opacity: _modeAnimation,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _firstNameController,
                          cursorColor: cursorColor,
                          style: TextStyle(
                            color: inputTextColor,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500,
                          ),
                          decoration: _inputDecoration(
                            'First Name',
                            Icons.person_outline,
                            isDark: isDark,
                          ),
                          validator: (v) =>
                              (_isSignUp && (v == null || v.trim().isEmpty))
                              ? 'Required'
                              : null,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: _lastNameController,
                          cursorColor: cursorColor,
                          style: TextStyle(
                            color: inputTextColor,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500,
                          ),
                          decoration: _inputDecoration(
                            'Last Name',
                            Icons.person_outline,
                            isDark: isDark,
                          ),
                          validator: (v) =>
                              (_isSignUp && (v == null || v.trim().isEmpty))
                              ? 'Required'
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Email
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              cursorColor: cursorColor,
              style: TextStyle(
                color: inputTextColor,
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
              ),
              decoration: _inputDecoration(
                'Email Address',
                Icons.email_outlined,
                isDark: isDark,
              ),
              validator: (v) => (v == null || !v.contains('@'))
                  ? 'Enter a valid email address'
                  : null,
            ),

            const SizedBox(height: 14),

            // Password
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              cursorColor: cursorColor,
              style: TextStyle(
                color: inputTextColor,
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
              ),
              decoration: _inputDecoration(
                'Password',
                Icons.lock_outline_rounded,
                isDark: isDark,
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: iconToggleColor,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Please enter a password';
                }
                if (_isSignUp && v.length < 8) {
                  return 'Password must be at least 8 characters long';
                }
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

            // Remember me & Forgot Password (fluidly visible in Sign In mode, collapses in Register mode)
            SizeTransition(
              sizeFactor: ReverseAnimation(_modeAnimation),
              alignment: Alignment.topCenter,
              child: FadeTransition(
                opacity: ReverseAnimation(_modeAnimation),
                child: Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 2),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _rememberMe = !_rememberMe),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                height: 20,
                                width: 20,
                                child: Checkbox(
                                  value: _rememberMe,
                                  onChanged: (val) =>
                                      setState(() => _rememberMe = val ?? true),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  activeColor: AppDesign.brand,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Remember me',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: subtitleColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: _showForgotPasswordDialog,
                          child: Text(
                            'Forgot Password?',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: AppDesign.accent(isDark),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Confirm password and notice smoothly animated via SizeTransition + FadeTransition
            SizeTransition(
              sizeFactor: _modeAnimation,
              alignment: Alignment.topCenter,
              child: FadeTransition(
                opacity: _modeAnimation,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _confirmPasswordController,
                      obscureText: _obscureConfirmPassword,
                      cursorColor: cursorColor,
                      style: TextStyle(
                        color: inputTextColor,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                      ),
                      decoration: _inputDecoration(
                        'Confirm Password',
                        Icons.lock_reset_rounded,
                        isDark: isDark,
                        suffixIcon: IconButton(
                          tooltip: _obscureConfirmPassword
                              ? 'Show confirm password'
                              : 'Hide confirm password',
                          icon: Icon(
                            _obscureConfirmPassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            color: iconToggleColor,
                            size: 20,
                          ),
                          onPressed: () => setState(
                            () => _obscureConfirmPassword =
                                !_obscureConfirmPassword,
                          ),
                        ),
                      ),
                      validator: (v) {
                        if (!_isSignUp) return null;
                        if (v == null || v.isEmpty) {
                          return 'Please confirm your password';
                        }
                        if (v != _passwordController.text) {
                          return 'Passwords do not match';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: AppDesign.brandWash(isDark),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: AppDesign.brandBorder(isDark),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.mark_email_read_outlined,
                            color: AppDesign.accent(isDark),
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'A 6-digit verification code will be sent to your email address immediately after registration.',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppDesign.accent(isDark),
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

            const SizedBox(height: 22),

            // Submit Button — primary brand blue with crisp contrast
            SizedBox(
              width: double.infinity,
              height: 50,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1D4ED8), AppDesign.brand],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppDesign.brand.withValues(
                        alpha: _isLoading ? 0.0 : 0.28,
                      ),
                      blurRadius: 12,
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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _isLoading ? null : _submitEmailAuth,
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          transitionBuilder: (child, anim) => FadeTransition(
                            opacity: anim,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0.0, 0.15),
                                end: Offset.zero,
                              ).animate(anim),
                              child: child,
                            ),
                          ),
                          child: Text(
                            _isSignUp
                                ? 'Create Account & Verify Email'
                                : 'Sign In to Portal',
                            key: ValueKey<bool>(_isSignUp),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14.5,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                ),
              ),
            ),

            const SizedBox(height: 14),

            // Trust footer
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 12,
                  color: subtitleColor,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    'Protected by Firebase Authentication',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: subtitleColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4.5),
      decoration: BoxDecoration(
        color: AppDesign.brandWash(isDark),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppDesign.brandBorder(isDark)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppDesign.accent(isDark)),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8),
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
    final String label = score == 1
        ? 'Weak'
        : score == 2
        ? 'Fair'
        : 'Strong';
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
                    color: i < score
                        ? barColor
                        : (isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFE2E8F0)),
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
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: barColor,
          ),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(
    String label,
    IconData icon, {
    Widget? suffixIcon,
    bool isDark = false,
  }) {
    final borderCol = isDark
        ? const Color(0xFF334155)
        : const Color(0xFFCBD5E1);
    final enabledBorderCol = isDark
        ? const Color(0xFF1E293B)
        : const Color(0xFFE2E8F0);
    final focusCol = AppDesign.accent(isDark);
    final fillCol = isDark
        ? const Color(0xFF0F172A).withValues(alpha: 0.75)
        : const Color(0xFFF8FAFC);
    final labelCol = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: labelCol,
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
      ),
      floatingLabelStyle: TextStyle(
        color: focusCol,
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.auto,
      prefixIcon: Icon(icon, color: labelCol, size: 19),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: fillCol,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: borderCol),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: enabledBorderCol, width: 1.1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: focusCol, width: 2.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 2.0),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
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

/// Animated pulsing sonar radar marker widget for road hazards on GIS map
class _PulsingLiveDot extends StatelessWidget {
  final Animation<double> animation;

  const _PulsingLiveDot({required this.animation});

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF10B981);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final progress = animation.value;
        final opacity = (1.0 - progress).clamp(0.0, 1.0);
        return SizedBox(
          width: 12,
          height: 12,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 6 + (progress * 6),
                height: 6 + (progress * 6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: opacity * 0.5),
                ),
              ),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Pixel-perfect vector Google G Logo (100% offline, zero network errors)
class GoogleGLogo extends StatelessWidget {
  final double size;
  const GoogleGLogo({super.key, this.size = 18});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: const CustomPaint(painter: GoogleGLogoPainter()),
    );
  }
}

class GoogleGLogoPainter extends CustomPainter {
  const GoogleGLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final center = Offset(w / 2, h / 2);
    final radius = w / 2;
    final thickness = w * 0.22;
    final strokeRadius = radius - (thickness / 2);

    final rect = Rect.fromCircle(center: center, radius: strokeRadius);

    Paint arcPaint(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.butt;

    // Red (top)
    canvas.drawArc(rect, -2.6, 1.6, false, arcPaint(const Color(0xFFEA4335)));
    // Yellow (left)
    canvas.drawArc(rect, -4.2, 1.6, false, arcPaint(const Color(0xFFFBBC05)));
    // Green (bottom)
    canvas.drawArc(rect, 0.5, 1.6, false, arcPaint(const Color(0xFF34A853)));
    // Blue (right)
    canvas.drawArc(rect, -0.6, 1.1, false, arcPaint(const Color(0xFF4285F4)));

    // Blue horizontal center bar
    final barPaint = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.fill;
    final barHeight = thickness;
    final barWidth = radius * 0.95;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          center.dx - 1,
          center.dy - (barHeight / 2),
          barWidth,
          barHeight,
        ),
        Radius.circular(thickness * 0.2),
      ),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
