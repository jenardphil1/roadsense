import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_design.dart';

/// Identifies each guided tour flow in the mobile app.
enum MobileTourId {
  main,
  search,
  directions,
  routePreview,
  driving,
  scanner,
  liveScanner,
  review,
  reports,
  profile,
}

/// Declarative definition for a single spotlight step anchored to a real
/// rendered widget via [targetKey].
class TourStepSpec {
  final String id;
  final GlobalKey targetKey;
  final String title;
  final String description;
  final IconData icon;
  final EdgeInsets spotlightPadding;
  final double borderRadius;

  const TourStepSpec({
    required this.id,
    required this.targetKey,
    required this.title,
    required this.description,
    this.icon = Icons.lightbulb_outline_rounded,
    this.spotlightPadding = const EdgeInsets.all(6),
    this.borderRadius = 16,
  });
}

/// Persists tour completion locally and drives active spotlight steps.
class MobileTourController extends ChangeNotifier {
  static const String mainPrefKey = 'mobile_tour_main_done_v1';
  static const String scannerPrefKey = 'mobile_tour_scanner_done_v1';
  static const String reviewPrefKey = 'mobile_tour_review_done_v1';

  bool _loaded = false;
  Future<void>? _loadingFuture;
  final Map<MobileTourId, bool> _completed = {
    for (final id in MobileTourId.values) id: false,
  };

  MobileTourId? _activeTour;
  List<TourStepSpec> _activeSteps = const [];
  int _currentIndex = 0;

  bool get isLoaded => _loaded;
  bool get isRunning => _activeTour != null && _activeSteps.isNotEmpty;
  MobileTourId? get activeTour => _activeTour;
  List<TourStepSpec> get steps => _activeSteps;
  int get currentIndex => _currentIndex;
  TourStepSpec? get currentStep =>
      (_activeSteps.isNotEmpty && _currentIndex < _activeSteps.length)
      ? _activeSteps[_currentIndex]
      : null;

  bool isCompleted(MobileTourId id) => _completed[id] ?? false;

  String _prefKey(MobileTourId id) {
    switch (id) {
      case MobileTourId.main:
        return mainPrefKey;
      case MobileTourId.search:
        return 'mobile_tour_search_done_v1';
      case MobileTourId.directions:
        return 'mobile_tour_directions_done_v1';
      case MobileTourId.routePreview:
        return 'mobile_tour_route_preview_done_v1';
      case MobileTourId.driving:
        return 'mobile_tour_driving_done_v1';
      case MobileTourId.scanner:
        return scannerPrefKey;
      case MobileTourId.liveScanner:
        return 'mobile_tour_live_scanner_done_v1';
      case MobileTourId.review:
        return reviewPrefKey;
      case MobileTourId.reports:
        return 'mobile_tour_reports_done_v1';
      case MobileTourId.profile:
        return 'mobile_tour_profile_done_v1';
    }
  }

  /// Ensures completion flags have been loaded from local preferences.
  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loadingFuture ??= load().whenComplete(() => _loadingFuture = null);
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final id in MobileTourId.values) {
        _completed[id] = prefs.getBool(_prefKey(id)) ?? false;
      }
    } catch (_) {
      // Keep default incomplete state if preferences are unavailable.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> markCompleted(MobileTourId id) async {
    _completed[id] = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey(id), true);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> resetAllTours() async {
    for (final id in MobileTourId.values) {
      _completed[id] = false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final id in MobileTourId.values) {
        await prefs.remove(_prefKey(id));
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Starts [id] with only currently mounted and visible [TourStepSpec] anchors.
  /// Returns true when at least one step can be displayed.
  bool startTour(
    MobileTourId id,
    List<TourStepSpec> candidates, {
    bool force = false,
  }) {
    if (!force && (!_loaded || isCompleted(id))) return false;
    if (isRunning) return false;

    final available = candidates.where(_isKeyAttached).toList();
    if (available.isEmpty) return false;

    _activeTour = id;
    _activeSteps = available;
    _currentIndex = 0;
    notifyListeners();
    return true;
  }

  bool _isKeyAttached(TourStepSpec step) {
    final ctx = step.targetKey.currentContext;
    if (ctx == null || !ctx.mounted) return false;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return false;
    final size = ro.size;
    return size.width > 0 && size.height > 0;
  }

  Future<void> next() async {
    if (!isRunning) return;
    if (_currentIndex + 1 >= _activeSteps.length) {
      await finish();
      return;
    }
    var candidate = _currentIndex + 1;
    while (candidate < _activeSteps.length &&
        !_isKeyAttached(_activeSteps[candidate])) {
      candidate++;
    }
    if (candidate >= _activeSteps.length) {
      await finish();
      return;
    }
    _currentIndex = candidate;
    notifyListeners();
  }

  void back() {
    if (!isRunning || _currentIndex <= 0) return;
    var candidate = _currentIndex - 1;
    while (candidate > 0 && !_isKeyAttached(_activeSteps[candidate])) {
      candidate--;
    }
    if (_isKeyAttached(_activeSteps[candidate])) {
      _currentIndex = candidate;
      notifyListeners();
    }
  }

  Future<void> skip() => finish();

  Future<void> finish() async {
    final tour = _activeTour;
    _activeTour = null;
    _activeSteps = const [];
    _currentIndex = 0;
    notifyListeners();
    if (tour != null) {
      await markCompleted(tour);
    }
  }

  void cancelWithoutCompleting() {
    if (!isRunning) return;
    _activeTour = null;
    _activeSteps = const [];
    _currentIndex = 0;
    notifyListeners();
  }
}

/// Interactive spotlight overlay anchored to real rendered widgets via
/// [GlobalKey] + [RenderBox]. Automatically handles SafeArea, keyboard insets,
/// scrolling off-screen anchors into view, viewport resizing/orientation changes,
/// large text scaling, screen readers, and reduced motion preferences.
class SpotlightTourOverlay extends StatefulWidget {
  final MobileTourController controller;

  const SpotlightTourOverlay({super.key, required this.controller});

  @override
  State<SpotlightTourOverlay> createState() => _SpotlightTourOverlayState();
}

class _SpotlightTourOverlayState extends State<SpotlightTourOverlay>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final GlobalKey _overlayKey = GlobalKey();
  late final AnimationController _pulseController;
  Rect? _targetRect;
  String? _syncedStepId;
  TourStepSpec? _lastEnsuredStep;
  Timer? _recomputeTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    widget.controller.addListener(_onControllerChanged);
    _scheduleAnchorSync(scrollIntoView: true);
  }

  @override
  void didUpdateWidget(covariant SpotlightTourOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _scheduleAnchorSync(scrollIntoView: true);
    }
  }

  @override
  void dispose() {
    _recomputeTimer?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleAnchorSync(scrollIntoView: false);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _scheduleAnchorSync(scrollIntoView: true);
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final nextId = widget.controller.currentStep?.id;
    if (nextId != _syncedStepId) {
      _targetRect = null;
      _syncedStepId = null;
    }
    _scheduleAnchorSync(scrollIntoView: true);
  }

  void _scheduleAnchorSync({required bool scrollIntoView}) {
    _recomputeTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncStepAnchor(scrollIntoView: scrollIntoView);
    });
  }

  Future<void> _syncStepAnchor({required bool scrollIntoView}) async {
    final step = widget.controller.currentStep;
    if (step == null) {
      _lastEnsuredStep = null;
      if (_targetRect != null) {
        setState(() => _targetRect = null);
      }
      _pulseController.stop();
      return;
    }

    final targetCtx = step.targetKey.currentContext;
    if (targetCtx == null || !targetCtx.mounted) {
      // Target disappeared mid-tour; skip cleanly to next available step.
      await widget.controller.next();
      return;
    }

    if (scrollIntoView && _lastEnsuredStep?.id != step.id) {
      _lastEnsuredStep = step;
      if (Scrollable.maybeOf(targetCtx) != null) {
        final disableAnimations = MediaQuery.disableAnimationsOf(context);
        try {
          await Scrollable.ensureVisible(
            targetCtx,
            alignment: 0.35,
            duration: disableAnimations
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        } catch (_) {}
      }
    }

    if (!mounted) return;
    final rect = _computeTargetRect(step);
    if (rect == null) {
      await widget.controller.next();
      return;
    }

    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion) {
      _pulseController.stop();
    } else if (!_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    }

    if (_targetRect != rect || _syncedStepId != step.id) {
      setState(() {
        _targetRect = rect;
        _syncedStepId = step.id;
      });
    }
  }

  Rect? _computeTargetRect(TourStepSpec step) {
    final overlayCtx = _overlayKey.currentContext;
    final targetCtx = step.targetKey.currentContext;
    if (overlayCtx == null || targetCtx == null || !targetCtx.mounted) {
      return null;
    }
    final overlayBox = overlayCtx.findRenderObject();
    final targetBox = targetCtx.findRenderObject();
    if (overlayBox is! RenderBox ||
        targetBox is! RenderBox ||
        !overlayBox.hasSize ||
        !targetBox.hasSize) {
      return null;
    }

    final size = targetBox.size;
    if (size.width <= 0 || size.height <= 0) return null;

    final topLeft = targetBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final rawRect = topLeft & size;
    final padded = Rect.fromLTRB(
      rawRect.left - step.spotlightPadding.left,
      rawRect.top - step.spotlightPadding.top,
      rawRect.right + step.spotlightPadding.right,
      rawRect.bottom + step.spotlightPadding.bottom,
    );

    // Clamp to overlay viewport with safe margin.
    final bounds = Offset.zero & overlayBox.size;
    final clamped = padded.intersect(bounds);
    if (clamped.isEmpty || clamped.width <= 0 || clamped.height <= 0) {
      return null;
    }
    return clamped;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final step = widget.controller.currentStep;
        if (step == null) {
          return const SizedBox.shrink();
        }

        final media = MediaQuery.of(context);
        final reducedMotion = media.disableAnimations;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final accent = AppDesign.accent(isDark);
        final stepsCount = widget.controller.steps.length;
        final stepNumber = widget.controller.currentIndex + 1;
        final rect =
            (_syncedStepId == step.id ? _targetRect : null) ??
            _computeTargetRect(step);

        return Positioned.fill(
          key: _overlayKey,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final overlayW =
                  constraints.maxWidth.isFinite && constraints.maxWidth > 0
                  ? constraints.maxWidth
                  : media.size.width;
              final overlayH =
                  constraints.maxHeight.isFinite && constraints.maxHeight > 0
                  ? constraints.maxHeight
                  : media.size.height;
              return CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): () =>
                      widget.controller.skip(),
                },
                child: Focus(
                  autofocus: true,
                  child: Semantics(
                    container: true,
                    explicitChildNodes: true,
                    child: Stack(
                      children: [
                        // Backdrop dimming everything except the target cutout.
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap:
                                () {}, // Prevent accidental clicks during tour
                            child: CustomPaint(
                              painter: _SpotlightScrimPainter(
                                cutoutRect: rect,
                                borderRadius: step.borderRadius,
                                scrimColor: Colors.black.withValues(
                                  alpha: 0.72,
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Focus halo around the highlighted control.
                        if (rect != null)
                          Positioned.fromRect(
                            rect: rect,
                            child: IgnorePointer(
                              child: reducedMotion
                                  ? _buildFocusBorder(
                                      step.borderRadius,
                                      accent,
                                      1.0,
                                    )
                                  : AnimatedBuilder(
                                      animation: _pulseController,
                                      builder: (context, _) =>
                                          _buildFocusBorder(
                                            step.borderRadius,
                                            accent,
                                            0.65 +
                                                (_pulseController.value * 0.35),
                                          ),
                                    ),
                            ),
                          ),

                        // Positioned tooltip & directional pointer without overlap.
                        if (rect != null)
                          _buildPositionedTooltip(
                            context: context,
                            media: media,
                            viewportW: overlayW,
                            viewportH: overlayH,
                            rect: rect,
                            step: step,
                            stepNumber: stepNumber,
                            totalSteps: stepsCount,
                            isDark: isDark,
                            accent: accent,
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildFocusBorder(double radius, Color accent, double opacity) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withValues(alpha: opacity),
          width: 2.5,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: opacity * 0.6),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }

  Widget _buildPositionedTooltip({
    required BuildContext context,
    required MediaQueryData media,
    required double viewportW,
    required double viewportH,
    required Rect rect,
    required TourStepSpec step,
    required int stepNumber,
    required int totalSteps,
    required bool isDark,
    required Color accent,
  }) {
    final screenW = viewportW;
    final screenH = viewportH;
    final bool isLandscape = screenW > screenH && screenH < 560;
    final safeLeft = math.max(12.0, media.padding.left + 12.0);
    final safeRight = math.max(12.0, media.padding.right + 12.0);
    final safeTop = math.max(12.0, media.padding.top + 8.0);
    final safeBottom = math.max(
      12.0,
      math.max(media.padding.bottom, media.viewInsets.bottom) + 8.0,
    );

    final usableWidth = math.max(200.0, screenW - safeLeft - safeRight);
    final tooltipWidth = math.min(360.0, usableWidth);

    // Center horizontally around target, clamped within horizontal safe margins.
    final preferredLeft = rect.center.dx - (tooltipWidth / 2);
    final left = preferredLeft.clamp(
      safeLeft,
      math.max(safeLeft, screenW - safeRight - tooltipWidth),
    );

    const arrowHeight = 10.0;
    const gap = 8.0;
    final spaceAbove = math.max(0.0, rect.top - safeTop - arrowHeight - gap);
    final spaceBelow = math.max(
      0.0,
      (screenH - safeBottom) - rect.bottom - arrowHeight - gap,
    );
    final spaceLeft = math.max(0.0, rect.left - safeLeft - gap);
    final spaceRight = math.max(0.0, (screenW - safeRight) - rect.right - gap);

    final bool hasSpaceAboveOrBelow = spaceBelow >= 130 || spaceAbove >= 130;
    final bool placeBesideInLandscape =
        isLandscape &&
        (!hasSpaceAboveOrBelow ||
            (math.max(spaceLeft, spaceRight) >= 260 &&
                math.max(spaceAbove, spaceBelow) < 170));
    final bool placeRight = spaceRight >= spaceLeft;
    final double effectiveWidth = placeBesideInLandscape
        ? math.min(
            340.0,
            math.max(220.0, placeRight ? spaceRight : spaceLeft),
          )
        : tooltipWidth;
    final bool placeBelow = spaceBelow >= spaceAbove || spaceBelow >= 190;
    final double usableViewportH = math.max(
      110.0,
      screenH - safeTop - safeBottom,
    );
    final double maxCardHeight = placeBesideInLandscape
        ? usableViewportH
        : (hasSpaceAboveOrBelow
              ? (placeBelow ? spaceBelow : spaceAbove)
              : math.min(usableViewportH * 0.65, usableViewportH));

    final arrowLocalX = (rect.center.dx - left).clamp(
      24.0,
      tooltipWidth - 24.0,
    );
    final cardSurface = AppDesign.surface(isDark);
    final border = AppDesign.border(isDark);

    final tooltipColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!placeBesideInLandscape && hasSpaceAboveOrBelow && placeBelow)
          Padding(
            padding: EdgeInsets.only(left: arrowLocalX - 9),
            child: CustomPaint(
              size: const Size(18, arrowHeight),
              painter: _ArrowTrianglePainter(
                color: cardSurface,
                borderColor: border,
                pointUp: true,
              ),
            ),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: effectiveWidth,
            maxHeight: maxCardHeight,
          ),
          child: Semantics(
            liveRegion: true,
            label:
                'Tour step $stepNumber of $totalSteps. ${step.title}. ${step.description}',
            child: Material(
              color: cardSurface,
              elevation: 8,
              shadowColor: Colors.black.withValues(alpha: isDark ? 0.45 : 0.16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppDesign.radiusLg),
                side: BorderSide(color: border, width: 1.0),
              ),
              child: SingleChildScrollView(
                padding: EdgeInsets.all(placeBesideInLandscape ? 12 : 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppDesign.brandWash(isDark),
                            borderRadius: BorderRadius.circular(
                              AppDesign.radiusPill,
                            ),
                            border: Border.all(
                              color: AppDesign.brandBorder(isDark),
                            ),
                          ),
                          child: Text(
                            '$stepNumber of $totalSteps',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: accent,
                            ),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: widget.controller.skip,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          child: Text(
                            'Skip',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppDesign.textSecondary(isDark),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(step.icon, size: 20, color: accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            step.title,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: AppDesign.textPrimary(isDark),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      step.description,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: AppDesign.textSecondary(isDark),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        if (widget.controller.currentIndex > 0)
                          OutlinedButton(
                            onPressed: widget.controller.back,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(76, 48),
                              side: BorderSide(color: border),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppDesign.radiusMd,
                                ),
                              ),
                            ),
                            child: Text(
                              'Back',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppDesign.textPrimary(isDark),
                              ),
                            ),
                          ),
                        ElevatedButton(
                          onPressed: widget.controller.next,
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(92, 48),
                            backgroundColor: AppDesign.brand,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppDesign.radiusMd,
                              ),
                            ),
                          ),
                          child: Text(
                            stepNumber >= totalSteps ? 'Done' : 'Next',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!placeBesideInLandscape && hasSpaceAboveOrBelow && !placeBelow)
          Padding(
            padding: EdgeInsets.only(left: arrowLocalX - 9),
            child: CustomPaint(
              size: const Size(18, arrowHeight),
              painter: _ArrowTrianglePainter(
                color: cardSurface,
                borderColor: border,
                pointUp: false,
              ),
            ),
          ),
      ],
    );

    if (placeBesideInLandscape) {
      final double sideLeft = placeRight
          ? (rect.right + gap).clamp(
              safeLeft,
              math.max(safeLeft, screenW - safeRight - effectiveWidth),
            )
          : (rect.left - gap - effectiveWidth).clamp(
              safeLeft,
              math.max(safeLeft, screenW - safeRight - effectiveWidth),
            );
      return Positioned(
        left: sideLeft,
        top: safeTop,
        bottom: safeBottom,
        width: effectiveWidth,
        child: Center(child: tooltipColumn),
      );
    }

    if (!hasSpaceAboveOrBelow) {
      return Positioned(
        left: left.toDouble(),
        bottom: safeBottom.toDouble(),
        width: tooltipWidth,
        child: tooltipColumn,
      );
    }

    if (placeBelow) {
      return Positioned(
        left: left.toDouble(),
        top: (rect.bottom + gap).toDouble(),
        width: tooltipWidth,
        child: tooltipColumn,
      );
    }

    return Positioned(
      left: left.toDouble(),
      bottom: (screenH - rect.top + gap).toDouble(),
      width: tooltipWidth,
      child: tooltipColumn,
    );
  }
}

class _SpotlightScrimPainter extends CustomPainter {
  final Rect? cutoutRect;
  final double borderRadius;
  final Color scrimColor;

  _SpotlightScrimPainter({
    required this.cutoutRect,
    required this.borderRadius,
    required this.scrimColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final full = Path()..addRect(Offset.zero & size);
    if (cutoutRect == null) {
      canvas.drawPath(full, Paint()..color = scrimColor);
      return;
    }
    final hole = Path()
      ..addRRect(
        RRect.fromRectAndRadius(cutoutRect!, Radius.circular(borderRadius)),
      );
    final combined = Path.combine(PathOperation.difference, full, hole);
    canvas.drawPath(combined, Paint()..color = scrimColor);
  }

  @override
  bool shouldRepaint(covariant _SpotlightScrimPainter oldDelegate) {
    return oldDelegate.cutoutRect != cutoutRect ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.scrimColor != scrimColor;
  }
}

class _ArrowTrianglePainter extends CustomPainter {
  final Color color;
  final Color borderColor;
  final bool pointUp;

  _ArrowTrianglePainter({
    required this.color,
    required this.borderColor,
    required this.pointUp,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fillPath = Path();
    if (pointUp) {
      fillPath
        ..moveTo(0, size.height)
        ..lineTo(size.width / 2, 0)
        ..lineTo(size.width, size.height)
        ..close();
    } else {
      fillPath
        ..moveTo(0, 0)
        ..lineTo(size.width / 2, size.height)
        ..lineTo(size.width, 0)
        ..close();
    }
    canvas.drawPath(fillPath, Paint()..color = color);

    final edgePath = Path();
    if (pointUp) {
      edgePath
        ..moveTo(0, size.height)
        ..lineTo(size.width / 2, 0)
        ..lineTo(size.width, size.height);
    } else {
      edgePath
        ..moveTo(0, 0)
        ..lineTo(size.width / 2, size.height)
        ..lineTo(size.width, 0);
    }
    canvas.drawPath(
      edgePath,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _ArrowTrianglePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.pointUp != pointUp;
  }
}
