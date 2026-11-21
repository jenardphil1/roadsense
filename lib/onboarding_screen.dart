import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_design.dart';
import 'app_settings.dart';
import 'dpwh_standards.dart';
import 'mobile_components.dart';

/// Preference key tracking whether user has completed the first-install onboarding
const String kHasSeenOnboardingPrefKey = 'has_seen_onboarding_v1';

/// Checks if this is a first-time install / launch
Future<bool> checkHasSeenOnboarding() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kHasSeenOnboardingPrefKey) ?? false;
  } catch (_) {
    return false;
  }
}

/// Marks onboarding as completed in local storage
Future<void> markOnboardingCompleted() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kHasSeenOnboardingPrefKey, true);
  } catch (_) {}
}

/// ─────────────────────────────────────────────────────────────────────────────
/// ROADSENSE AI — ENTERPRISE TELEMETRY ONBOARDING & INTERACTIVE USER GUIDE
/// Designed with Linear / Notion / Supabase enterprise telemetry HUD aesthetic.
/// ─────────────────────────────────────────────────────────────────────────────
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;
  final bool isReviewMode;

  const OnboardingScreen({
    super.key,
    required this.onComplete,
    this.isReviewMode = false,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  static const int _totalPages = 5;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);

    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _goToPage(int page) {
    HapticFeedback.selectionClick();
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulseController.stop();
    } else if (!_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    }
  }

  void _nextPage() {
    if (_currentPage < _totalPages - 1) {
      _goToPage(_currentPage + 1);
    } else {
      _finishOnboarding();
    }
  }

  Future<void> _finishOnboarding() async {
    HapticFeedback.mediumImpact();
    if (!widget.isReviewMode) {
      await markOnboardingCompleted();
    }
    widget.onComplete();
  }

  Future<void> _requestPermissionsAndFinish() async {
    HapticFeedback.mediumImpact();
    try {
      await Geolocator.requestPermission();
    } catch (_) {}
    await _finishOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeModeNotifier,
      builder: (context, themeMode, _) {
        final bool isDark = AppSettings.instance.isDarkMode;
        final Color bgColor = AppDesign.bg(isDark);
        final Color cardColor = AppDesign.surface(isDark);
        final Color textColor = AppDesign.textPrimary(isDark);
        final Color subtextColor = AppDesign.textSecondary(isDark);
        final Color mutedColor = AppDesign.textMuted(isDark);
        final Color accentColor = AppDesign.accent(isDark);
        final Color borderColor = AppDesign.border(isDark);

        return Scaffold(
          backgroundColor: bgColor,
          body: SafeArea(
            child: Column(
              children: [
                // ── HUD TOP BAR ───────────────────────────────────────────────
                _buildTopBar(
                  isDark,
                  textColor,
                  subtextColor,
                  accentColor,
                  borderColor,
                ),

                // ── MAIN SLIDES VIEW ──────────────────────────────────────────
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (idx) {
                      setState(() => _currentPage = idx);
                    },
                    children: [
                      _buildWelcomeSlide(
                        isDark,
                        textColor,
                        subtextColor,
                        mutedColor,
                        accentColor,
                        cardColor,
                        borderColor,
                      ),
                      _buildScannerSlide(
                        isDark,
                        textColor,
                        subtextColor,
                        mutedColor,
                        accentColor,
                        cardColor,
                        borderColor,
                      ),
                      _buildNavigationSlide(
                        isDark,
                        textColor,
                        subtextColor,
                        mutedColor,
                        accentColor,
                        cardColor,
                        borderColor,
                      ),
                      _buildReportingSlide(
                        isDark,
                        textColor,
                        subtextColor,
                        mutedColor,
                        accentColor,
                        cardColor,
                        borderColor,
                      ),
                      _buildPermissionsSlide(
                        isDark,
                        textColor,
                        subtextColor,
                        mutedColor,
                        accentColor,
                        cardColor,
                        borderColor,
                      ),
                    ],
                  ),
                ),

                // ── BOTTOM CONTROLS & HUD DOCK ────────────────────────────────
                _buildBottomDock(
                  isDark,
                  textColor,
                  subtextColor,
                  accentColor,
                  borderColor,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── CLEAN CIVIC TOP BAR ────────────────────────────────────────────────────
  Widget _buildTopBar(
    bool isDark,
    Color textColor,
    Color subtextColor,
    Color accentColor,
    Color borderColor,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppDesign.surface(isDark),
        border: Border(bottom: BorderSide(color: borderColor, width: 1.0)),
      ),
      child: Row(
        children: [
          RoadSenseLogo(size: 32, showWordmark: true, isDarkOverride: isDark),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppDesign.brandWash(isDark),
              borderRadius: BorderRadius.circular(AppDesign.radiusPill),
              border: Border.all(color: AppDesign.brandBorder(isDark)),
            ),
            child: Text(
              'Step ${_currentPage + 1} of $_totalPages',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: accentColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (widget.isReviewMode)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                minimumSize: const Size(64, 48),
                foregroundColor: subtextColor,
              ),
              child: const Text(
                'Close',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            )
          else if (_currentPage < _totalPages - 1)
            TextButton(
              onPressed: _finishOnboarding,
              style: TextButton.styleFrom(
                minimumSize: const Size(56, 48),
                foregroundColor: subtextColor,
              ),
              child: const Text(
                'Skip',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }

  // ── SLIDE 1: WELCOME TO ROADSENSE AI ─────────────────────────────────────────
  Widget _buildWelcomeSlide(
    bool isDark,
    Color textColor,
    Color subtextColor,
    Color mutedColor,
    Color accentColor,
    Color cardColor,
    Color borderColor,
  ) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8),
          // Approved RoadSense AI Brand Emblem Hero
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, _) {
              return Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppDesign.brandWash(isDark),
                  border: Border.all(
                    color: accentColor.withValues(
                      alpha: 0.28 + (_pulseAnimation.value * 0.25),
                    ),
                    width: 1.5,
                  ),
                ),
                child: RoadSenseLogo(size: 76, isDarkOverride: isDark),
              );
            },
          ),
          const SizedBox(height: 20),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppDesign.brandWash(isDark),
              borderRadius: BorderRadius.circular(AppDesign.radiusPill),
              border: Border.all(color: AppDesign.brandBorder(isDark)),
            ),
            child: Text(
              'ROAD DEFECT MONITORING & NAVIGATION',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: accentColor,
              ),
            ),
          ),
          const SizedBox(height: 12),

          Text(
            'Welcome to RoadSense AI',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: textColor,
            ),
          ),
          const SizedBox(height: 8),

          Text(
            'Inspect live road conditions across Bulacan, scan defects with on-device AI, and track municipal repair reports in one unified platform.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: subtextColor, height: 1.5),
          ),
          const SizedBox(height: 22),

          _buildStructuredCard(
            isDark: isDark,
            icon: Icons.camera_alt_rounded,
            iconColor: accentColor,
            title: 'Live AI Road Scanner',
            subtitle:
                'Detects 4 DPWH distress classes directly from the live road scanner.',
            badgeText: 'ON-DEVICE AI',
            badgeColor: accentColor,
            textColor: textColor,
            subtextColor: subtextColor,
            borderColor: borderColor,
            cardColor: cardColor,
          ),
          const SizedBox(height: 10),

          _buildStructuredCard(
            isDark: isDark,
            icon: Icons.alt_route_rounded,
            iconColor: const Color(0xFF047857),
            title: 'Hazard-Aware Map & Routing',
            subtitle:
                'Search places and road reports, inspect defects, and navigate safer routes.',
            badgeText: 'LIVE MAP',
            badgeColor: const Color(0xFF047857),
            textColor: textColor,
            subtextColor: subtextColor,
            borderColor: borderColor,
            cardColor: cardColor,
          ),
          const SizedBox(height: 10),

          _buildStructuredCard(
            isDark: isDark,
            icon: Icons.verified_rounded,
            iconColor: const Color(0xFFB45309),
            title: 'DPWH Standards & SLA Tracking',
            subtitle:
                'Follows Department Order No. 41 categories and tracks Pending to Approved review.',
            badgeText: 'CIVIC REPORTS',
            badgeColor: const Color(0xFFB45309),
            textColor: textColor,
            subtextColor: subtextColor,
            borderColor: borderColor,
            cardColor: cardColor,
          ),
        ],
      ),
    );
  }

  // ── SLIDE 2: AI CAMERA SCANNER ──────────────────────────────────────────────
  Widget _buildScannerSlide(
    bool isDark,
    Color textColor,
    Color subtextColor,
    Color mutedColor,
    Color accentColor,
    Color cardColor,
    Color borderColor,
  ) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Clean Camera Detection Preview
          Container(
            height: 176,
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(AppDesign.radiusLg),
              border: Border.all(color: borderColor, width: 1.2),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _ViewfinderGridPainter()),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: _buildCornerBracket(
                    isTop: true,
                    isLeft: true,
                    color: accentColor,
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: _buildCornerBracket(
                    isTop: true,
                    isLeft: false,
                    color: accentColor,
                  ),
                ),
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: _buildCornerBracket(
                    isTop: false,
                    isLeft: true,
                    color: accentColor,
                  ),
                ),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: _buildCornerBracket(
                    isTop: false,
                    isLeft: false,
                    color: accentColor,
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 16,
                  right: 16,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppDesign.success,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Live Scanner Preview',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: AppDesign.brand.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(
                            AppDesign.radiusPill,
                          ),
                          border: Border.all(
                            color: const Color(0xFF60A5FA),
                            width: 0.8,
                          ),
                        ),
                        child: const Text(
                          'AI Ready',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 46,
                  left: 28,
                  child: _buildBoundingBox(
                    label: 'Pothole • 94%',
                    telemetry: 'CODE 01',
                    color: DpwhStandards.pothole.color,
                    width: 132,
                    height: 56,
                  ),
                ),
                Positioned(
                  bottom: 20,
                  right: 26,
                  child: _buildBoundingBox(
                    label: 'Alligator crack • 89%',
                    telemetry: 'CODE 02',
                    color: DpwhStandards.alligatorCrack.color,
                    width: 152,
                    height: 54,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppDesign.brandWash(isDark),
              borderRadius: BorderRadius.circular(AppDesign.radiusPill),
              border: Border.all(color: AppDesign.brandBorder(isDark)),
            ),
            child: Text(
              '4-CLASS ROAD DEFECT SCANNER',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: accentColor,
              ),
            ),
          ),
          const SizedBox(height: 10),

          Text(
            'Scan & Review Road Defects',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: textColor,
            ),
          ),
          const SizedBox(height: 8),

          Text(
            'Aim your phone camera at the road surface ahead. Save a detection frame for review, inspect the boxes, add notes, and submit with GPS proof.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: subtextColor, height: 1.45),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: _buildModeCard(
                  isDark: isDark,
                  icon: Icons.videocam_rounded,
                  iconColor: accentColor,
                  title: 'Live AI Scanner',
                  description:
                      'Real-time 4-class road scanning with cropped save-frame capture.',
                  borderColor: borderColor,
                  cardColor: cardColor,
                  textColor: textColor,
                  subtextColor: subtextColor,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildModeCard(
                  isDark: isDark,
                  icon: Icons.fact_check_rounded,
                  iconColor: const Color(0xFF047857),
                  title: 'Review & Submit',
                  description:
                      'Verify bounding boxes on the saved frame before GPS upload.',
                  borderColor: borderColor,
                  cardColor: cardColor,
                  textColor: textColor,
                  subtextColor: subtextColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: AppDesign.cardDecoration(
              isDark: isDark,
              radius: AppDesign.radiusLg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DETECTED DPWH DEFECT CLASSES',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.7,
                    color: subtextColor,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: DpwhStandards.allClasses
                      .map(
                        (cls) =>
                            MobileDefectPill(defectClass: cls, showCode: true),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── SLIDE 3: HAZARD AVOIDANCE NAVIGATION ────────────────────────────────────
  Widget _buildNavigationSlide(
    bool isDark,
    Color textColor,
    Color subtextColor,
    Color mutedColor,
    Color accentColor,
    Color cardColor,
    Color borderColor,
  ) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            height: 176,
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppDesign.sunken(isDark),
              borderRadius: BorderRadius.circular(AppDesign.radiusLg),
              border: Border.all(color: borderColor, width: 1.2),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TacticalMapPainter(
                      isDark: isDark,
                      accentColor: accentColor,
                    ),
                  ),
                ),
                Positioned(
                  top: 10,
                  left: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: AppDesign.cardDecoration(
                      isDark: isDark,
                      radius: AppDesign.radiusMd,
                      elevated: true,
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: AppDesign.success.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(
                              AppDesign.radiusSm,
                            ),
                          ),
                          child: const Icon(
                            Icons.turn_right_rounded,
                            color: Color(0xFF047857),
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'In 120m, turn right onto Rizal St',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: textColor,
                                ),
                              ),
                              const Text(
                                'Route avoids reported pothole cluster',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF047857),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppDesign.brandWash(isDark),
                            borderRadius: BorderRadius.circular(
                              AppDesign.radiusSm,
                            ),
                          ),
                          child: Text(
                            '4 min',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: accentColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: 66,
                  left: 32,
                  child: _buildMapPin('A', AppDesign.brand),
                ),
                Positioned(
                  top: 98,
                  left: 140,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: AppDesign.danger,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                      boxShadow: AppDesign.shadowSm(isDark),
                    ),
                    child: const Icon(
                      Icons.warning_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 16,
                  right: 36,
                  child: _buildMapPin('B', AppDesign.danger),
                ),
                Positioned(
                  bottom: 8,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(AppDesign.radiusPill),
                      border: Border.all(color: AppDesign.warning, width: 0.8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.volume_up_rounded,
                          color: Color(0xFFFBBF24),
                          size: 12,
                        ),
                        SizedBox(width: 5),
                        Text(
                          'Voice hazard alerts on',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF047857).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppDesign.radiusPill),
              border: Border.all(
                color: const Color(0xFF047857).withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              'MAP & HAZARD AVOIDANCE',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: isDark
                    ? const Color(0xFF34D399)
                    : const Color(0xFF047857),
              ),
            ),
          ),
          const SizedBox(height: 10),

          Text(
            'Hazard-Aware Smart Navigation',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: textColor,
            ),
          ),
          const SizedBox(height: 8),

          Text(
            'Explore verified road defects across Bulacan, filter by distress type or status, and plan safer routes with advance warnings.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: subtextColor, height: 1.45),
          ),
          const SizedBox(height: 16),

          _buildTelemetryNavRow(
            isDark: isDark,
            icon: Icons.alt_route_rounded,
            iconColor: isDark
                ? const Color(0xFF34D399)
                : const Color(0xFF047857),
            title: 'Safer Alternative Routes',
            description:
                'Finds routes around confirmed severe road distress clusters.',
            tag: 'SMART ROUTING',
            textColor: textColor,
            subtextColor: subtextColor,
            borderColor: borderColor,
            cardColor: cardColor,
          ),
          const SizedBox(height: 8),

          _buildTelemetryNavRow(
            isDark: isDark,
            icon: Icons.record_voice_over_rounded,
            iconColor: isDark
                ? const Color(0xFFFBBF24)
                : const Color(0xFFB45309),
            title: 'Spoken Hazard Alerts',
            description:
                'Audio warnings alert you 100m before reported hazards.',
            tag: 'HANDS-FREE',
            textColor: textColor,
            subtextColor: subtextColor,
            borderColor: borderColor,
            cardColor: cardColor,
          ),
          const SizedBox(height: 8),

          _buildTelemetryNavRow(
            isDark: isDark,
            icon: Icons.tune_rounded,
            iconColor: accentColor,
            title: '4-Class Map Filters & Search',
            description:
                'Search places or road reports and filter by defect type or approval status.',
            tag: 'MAP TOOLS',
            textColor: textColor,
            subtextColor: subtextColor,
            borderColor: borderColor,
            cardColor: cardColor,
          ),
        ],
      ),
    );
  }

  // ── SLIDE 4: CIVIC REPORTING & DPWH SLA ─────────────────────────────────────
  Widget _buildReportingSlide(
    bool isDark,
    Color textColor,
    Color subtextColor,
    Color mutedColor,
    Color accentColor,
    Color cardColor,
    Color borderColor,
  ) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const MobileReportLifecycleBanner(activeStage: 2),
          const SizedBox(height: 18),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFB45309).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppDesign.radiusPill),
              border: Border.all(
                color: const Color(0xFFB45309).withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              'REPORT LIFECYCLE & DPWH STANDARDS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: isDark
                    ? const Color(0xFFFBBF24)
                    : const Color(0xFFB45309),
              ),
            ),
          ),
          const SizedBox(height: 10),

          Text(
            'From Scan to Verified Repair',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: textColor,
            ),
          ),
          const SizedBox(height: 8),

          Text(
            'Saving a scan keeps it local for review. Submitted reports enter Pending review for LGU & DPWH verification before appearing to all drivers.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: subtextColor, height: 1.45),
          ),
          const SizedBox(height: 16),

          Container(
            padding: const EdgeInsets.all(14),
            decoration: AppDesign.cardDecoration(
              isDark: isDark,
              radius: AppDesign.radiusLg,
            ),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppDesign.danger.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(AppDesign.radiusSm),
                        border: Border.all(
                          color: AppDesign.danger.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        'CODE 01 & 02',
                        style: TextStyle(
                          color: isDark
                              ? const Color(0xFFFCA5A5)
                              : const Color(0xFFB91C1C),
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '3-Day Urgent Repair SLA',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Potholes and alligator cracking require prompt cold-mix or hot-mix patching.',
                            style: TextStyle(
                              fontSize: 12,
                              color: subtextColor,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Divider(color: borderColor, height: 22),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF047857).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(AppDesign.radiusSm),
                        border: Border.all(
                          color: const Color(0xFF047857).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        'CODE 12',
                        style: TextStyle(
                          color: isDark
                              ? const Color(0xFF34D399)
                              : const Color(0xFF047857),
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '30-Day Routine Sealant SLA',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Longitudinal and transverse cracks are scheduled for routine crack sealing.',
                            style: TextStyle(
                              fontSize: 12,
                              color: subtextColor,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppDesign.brandWash(isDark),
              borderRadius: BorderRadius.circular(AppDesign.radiusMd),
              border: Border.all(color: AppDesign.brandBorder(isDark)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.assignment_turned_in_rounded,
                  color: accentColor,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Follow status updates from Pending review to Approved in your Reports tab.',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: textColor,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── SLIDE 5: SYSTEM PERMISSIONS ─────────────────────────────────────────────
  Widget _buildPermissionsSlide(
    bool isDark,
    Color textColor,
    Color subtextColor,
    Color mutedColor,
    Color accentColor,
    Color cardColor,
    Color borderColor,
  ) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8),

          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF047857).withValues(alpha: 0.12),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF34D399)
                    : const Color(0xFF047857),
                width: 1.5,
              ),
            ),
            child: Icon(
              Icons.verified_user_rounded,
              size: 40,
              color: isDark ? const Color(0xFF34D399) : const Color(0xFF047857),
            ),
          ),
          const SizedBox(height: 18),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppDesign.brandWash(isDark),
              borderRadius: BorderRadius.circular(AppDesign.radiusPill),
              border: Border.all(color: AppDesign.brandBorder(isDark)),
            ),
            child: Text(
              'PERMISSIONS & PRIVACY',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: accentColor,
              ),
            ),
          ),
          const SizedBox(height: 10),

          Text(
            'Ready to Start Scanning',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: textColor,
            ),
          ),
          const SizedBox(height: 8),

          Text(
            'RoadSense needs GPS location and camera access so every report is accurately geotagged and road alerts work in real time:',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: subtextColor, height: 1.45),
          ),
          const SizedBox(height: 18),

          _buildHardwarePermissionCard(
            isDark: isDark,
            icon: Icons.my_location_rounded,
            title: 'GPS Location Access',
            description:
                'Used for live map positioning, hazard proximity alerts, and barangay/GPS geotagging.',
            statusTag: 'NAVIGATION & REPORTS',
            statusColor: accentColor,
            cardColor: cardColor,
            borderColor: borderColor,
            textColor: textColor,
            subtextColor: subtextColor,
          ),
          const SizedBox(height: 10),

          _buildHardwarePermissionCard(
            isDark: isDark,
            icon: Icons.camera_alt_rounded,
            title: 'Camera Scanner Access',
            description:
                'Used strictly for on-device road defect detection and saving photo evidence for review.',
            statusTag: 'AI SCANNER',
            statusColor: isDark
                ? const Color(0xFFFBBF24)
                : const Color(0xFFB45309),
            cardColor: cardColor,
            borderColor: borderColor,
            textColor: textColor,
            subtextColor: subtextColor,
          ),
          const SizedBox(height: 14),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppDesign.sunken(isDark),
              borderRadius: BorderRadius.circular(AppDesign.radiusMd),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Icon(Icons.lock_rounded, size: 16, color: mutedColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'All video inference runs locally on your device. Photos only upload when you submit a report.',
                    style: TextStyle(fontSize: 12, color: subtextColor),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── BOTTOM CONTROLS DOCK ────────────────────────────────────────────────────
  Widget _buildBottomDock(
    bool isDark,
    Color textColor,
    Color subtextColor,
    Color accentColor,
    Color borderColor,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: AppDesign.surface(isDark),
        border: Border(top: BorderSide(color: borderColor, width: 1.0)),
      ),
      child: Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(_totalPages, (index) {
              final bool isSelected = _currentPage == index;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                margin: const EdgeInsets.only(right: 6),
                width: isSelected ? 22 : 7,
                height: 6,
                decoration: BoxDecoration(
                  color: isSelected
                      ? accentColor
                      : AppDesign.borderStrong(isDark),
                  borderRadius: BorderRadius.circular(AppDesign.radiusPill),
                ),
              );
            }),
          ),
          const Spacer(),

          if (_currentPage > 0)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: OutlinedButton(
                onPressed: () => _goToPage(_currentPage - 1),
                style: AppDesign.outlinedButtonStyle(
                  isDark: isDark,
                  borderRadius: AppDesign.radiusMd,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.arrow_back_rounded, size: 16, color: textColor),
                    const SizedBox(width: 6),
                    Text(
                      'BACK',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (_currentPage == _totalPages - 1)
            ElevatedButton(
              onPressed: _requestPermissionsAndFinish,
              style: AppDesign.primaryButtonStyle(
                isDark: isDark,
                borderRadius: AppDesign.radiusMd,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.check_circle_outline_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                  SizedBox(width: 6),
                  Text(
                    'GET STARTED',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            )
          else
            ElevatedButton(
              onPressed: _nextPage,
              style: AppDesign.primaryButtonStyle(
                isDark: isDark,
                borderRadius: AppDesign.radiusMd,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'NEXT',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  SizedBox(width: 6),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── HELPER ATOMIC WIDGETS ───────────────────────────────────────────────────

  Widget _buildStructuredCard({
    required bool isDark,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String badgeText,
    required Color badgeColor,
    required Color textColor,
    required Color subtextColor,
    required Color borderColor,
    required Color cardColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: AppDesign.cardDecoration(
        isDark: isDark,
        radius: AppDesign.radiusLg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppDesign.radiusMd),
              border: Border.all(color: iconColor.withValues(alpha: 0.25)),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: textColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2.5,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppDesign.radiusSm),
                      ),
                      child: Text(
                        badgeText,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: badgeColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: subtextColor,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeCard({
    required bool isDark,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
    required Color borderColor,
    required Color cardColor,
    required Color textColor,
    required Color subtextColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: AppDesign.cardDecoration(
        isDark: isDark,
        radius: AppDesign.radiusLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppDesign.radiusMd),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
              color: textColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(fontSize: 12, color: subtextColor, height: 1.35),
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryNavRow({
    required bool isDark,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
    required String tag,
    required Color textColor,
    required Color subtextColor,
    required Color borderColor,
    required Color cardColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: AppDesign.cardDecoration(
        isDark: isDark,
        radius: AppDesign.radiusLg,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppDesign.radiusMd),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: textColor,
                        ),
                      ),
                    ),
                    Text(
                      tag,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: iconColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: subtextColor,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHardwarePermissionCard({
    required bool isDark,
    required IconData icon,
    required String title,
    required String description,
    required String statusTag,
    required Color statusColor,
    required Color cardColor,
    required Color borderColor,
    required Color textColor,
    required Color subtextColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: AppDesign.cardDecoration(
        isDark: isDark,
        radius: AppDesign.radiusLg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppDesign.radiusMd),
              border: Border.all(color: statusColor.withValues(alpha: 0.3)),
            ),
            child: Icon(icon, color: statusColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: textColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2.5,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppDesign.radiusSm),
                      ),
                      child: Text(
                        statusTag,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: statusColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: subtextColor,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBoundingBox({
    required String label,
    required String telemetry,
    required Color color,
    required double width,
    required double height,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(4),
        color: color.withValues(alpha: 0.14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            color: color,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(3),
            child: Text(
              telemetry,
              style: TextStyle(
                color: color,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCornerBracket({
    required bool isTop,
    required bool isLeft,
    required Color color,
  }) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        border: Border(
          top: isTop ? BorderSide(color: color, width: 2) : BorderSide.none,
          bottom: !isTop ? BorderSide(color: color, width: 2) : BorderSide.none,
          left: isLeft ? BorderSide(color: color, width: 2) : BorderSide.none,
          right: !isLeft ? BorderSide(color: color, width: 2) : BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildMapPin(String letter, Color color) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Center(
        child: Text(
          letter,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

/// Perspective viewfinder background lines for Slide 2
class _ViewfinderGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1;

    // Horizon line
    canvas.drawLine(
      Offset(0, size.height * 0.5),
      Offset(size.width, size.height * 0.5),
      linePaint,
    );

    // Perspective vanishing lines
    final vp = Offset(size.width * 0.5, size.height * 0.45);
    canvas.drawLine(vp, Offset(0, size.height), linePaint);
    canvas.drawLine(vp, Offset(size.width * 0.35, size.height), linePaint);
    canvas.drawLine(vp, Offset(size.width * 0.65, size.height), linePaint);
    canvas.drawLine(vp, Offset(size.width, size.height), linePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Tactical route painter rendering streets and a curved safe detour around a hazard for Slide 3
class _TacticalMapPainter extends CustomPainter {
  final bool isDark;
  final Color accentColor;

  _TacticalMapPainter({required this.isDark, required this.accentColor});

  @override
  void paint(Canvas canvas, Size size) {
    final streetPaint = Paint()
      ..color = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.square;

    // Background road corridors
    canvas.drawLine(Offset(20, 77), Offset(size.width - 20, 77), streetPaint);
    canvas.drawLine(
      Offset(size.width * 0.45, 10),
      Offset(size.width * 0.45, size.height - 10),
      streetPaint,
    );
    canvas.drawLine(
      Offset(20, size.height - 28),
      Offset(size.width - 20, size.height - 28),
      streetPaint,
    );

    // Blocked route segment through hazard
    final blockedPaint = Paint()
      ..color = const Color(0xFFEF4444).withValues(alpha: 0.35)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final blockedPath = Path();
    blockedPath.moveTo(44, 77);
    blockedPath.lineTo(size.width * 0.45, 77);
    blockedPath.lineTo(size.width - 48, size.height - 28);
    canvas.drawPath(blockedPath, blockedPaint);

    // Safe green/cyan calculated detour route around hazard
    final detourPaint = Paint()
      ..color = const Color(0xFF10B981)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final detourPath = Path();
    detourPath.moveTo(44, 77);
    detourPath.lineTo(size.width * 0.32, 77);
    detourPath.quadraticBezierTo(
      size.width * 0.35,
      135,
      size.width * 0.55,
      140,
    );
    detourPath.lineTo(size.width - 48, size.height - 28);
    canvas.drawPath(detourPath, detourPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
