/// Web-only design system for the RoadSense GIS web platform.
///
/// The mobile app owns [AppDesign] (lib/app_design.dart) and both apps read
/// their colour tokens from it. Everything else the web UI needs — the type
/// scale, the spacing/radius/icon scales, the status system, the shared widgets
/// and the [WebDesign.buildTheme] handed to `web_main.dart` — lives here, so the
/// web UI can change without editing a file the mobile app compiles against.
/// See CLAUDE.md section 1 (Strict Platform Separation).
library;

import 'package:flutter/material.dart';

import 'app_design.dart';

/// What a submission or account state *means*.
///
/// Brand blue is never a status and green/amber/red are never brand, so a chip's
/// colour carries the same meaning on every web screen.
enum StatusTone { approved, pending, rejected, info, neutral }

/// Resolved colours, icon and label for one [StatusTone] in one theme.
class StatusStyle {
  final Color fg;
  final Color bg;
  final Color outline;
  final IconData icon;
  final String label;

  const StatusStyle({
    required this.fg,
    required this.bg,
    required this.outline,
    required this.icon,
    required this.label,
  });
}

class WebDesign {
  WebDesign._();

  // ── Brand ─────────────────────────────────────────────────────────────────
  // Exactly one interactive colour: blue. Nav selection, primary buttons,
  // links, focus rings and progress all use it, and nothing else does.
  static Color brand(bool isDark) => const Color(0xFF2563EB);

  /// Tinted brand wash for selected rows and active pills.
  static Color brandWash(bool isDark) =>
      const Color(0xFF2563EB).withValues(alpha: isDark ? 0.20 : 0.10);

  /// Brand text/icon colour that stays legible on [surface].
  static Color brandOnSurface(bool isDark) => const Color(0xFF2563EB);

  // ── Status palette (semantic only — never brand) ───────────────────────────
  static const Color approvedLight = Color(0xFF047857);
  static const Color approvedDark = Color(0xFF34D399);
  static const Color pendingLight = Color(0xFFB45309);
  static const Color pendingDark = Color(0xFFFBBF24);
  static const Color rejectedLight = Color(0xFFB91C1C);
  static const Color rejectedDark = Color(0xFFFCA5A5);

  /// Solid fill for a semantic *action* button (Approve). Distinct from the
  /// chip foreground, which has to survive on a tinted background instead.
  static const Color approveAction = Color(0xFF059669);

  /// Destructive action colour — legible as a border or label in both themes.
  static Color danger(bool isDark) => isDark ? rejectedDark : rejectedLight;

  // ── Surfaces (delegated to the shared colour tokens) ──────────────────────
  static Color bg(bool isDark) => AppDesign.bg(isDark);
  static Color surface(bool isDark) => AppDesign.surface(isDark);
  static Color border(bool isDark) => AppDesign.border(isDark);
  static Color textPrimary(bool isDark) => AppDesign.textPrimary(isDark);
  static Color textSecondary(bool isDark) => AppDesign.textSecondary(isDark);
  static Color textMuted(bool isDark) => AppDesign.textMuted(isDark);

  /// Recessed surface: inputs, table headers, coordinate pills.
  static Color sunken(bool isDark) =>
      isDark ? const Color(0xFF0D1524) : const Color(0xFFF1F5F9);

  /// Row hover / subtle highlight.
  static Color hover(bool isDark) =>
      isDark ? const Color(0xFF1A2436) : const Color(0xFFF8FAFC);

  // ── Spacing (4pt rhythm) ──────────────────────────────────────────────────
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 20;
  static const double space6 = 24;
  static const double space8 = 32;
  static const double space10 = 40;
  static const double space12 = 48;

  // ── Radius ────────────────────────────────────────────────────────────────
  static const double radiusSm = 6;
  static const double radiusMd = 10;
  static const double radiusLg = 14;
  static const double radiusXl = 20;
  static const double radiusPill = 999;

  // ── Icon sizes ────────────────────────────────────────────────────────────
  static const double icon2xs = 12;
  static const double iconXs = 14;
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 24;
  static const double iconXl = 32;

  // ── Layout ────────────────────────────────────────────────────────────────
  static const double contentMaxWidth = 1400;
  static const double sidebarWidth = 264;
  static const double headerHeight = 64;
  static const double desktopBreakpoint = 900;
  static const double wideBreakpoint = 1280;

  /// Comfortable pointer target. WCAG 2.2 AA requires 24px on the web; 40 keeps
  /// dense toolbars usable without feeling touch-sized.
  static const double minTarget = 40;

  /// Horizontal gutters widen with the viewport instead of staying at a fixed 24.
  static EdgeInsets pageInsets(double width) => EdgeInsets.symmetric(
    horizontal: width < 640
        ? space4
        : (width < wideBreakpoint ? space6 : space8),
    vertical: width < 640 ? space4 : space6,
  );

  // ── Elevation ─────────────────────────────────────────────────────────────
  static List<BoxShadow> shadowSm(bool isDark) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.04),
      blurRadius: 3,
      offset: const Offset(0, 1),
    ),
  ];

  static List<BoxShadow> shadowMd(bool isDark) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.34 : 0.06),
      blurRadius: 10,
      offset: const Offset(0, 3),
    ),
  ];

  static List<BoxShadow> shadowLg(bool isDark) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.44 : 0.10),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];

  // ── Motion ────────────────────────────────────────────────────────────────
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 280);
  static const Curve easeOut = Curves.easeOutCubic;

  // ── Status resolution ─────────────────────────────────────────────────────
  /// Maps a Firestore `status` string to a tone. Unknown values read as pending
  /// so a typo never renders as "approved".
  static StatusTone toneOf(String? status) {
    switch (status) {
      case 'approved':
        return StatusTone.approved;
      case 'rejected':
        return StatusTone.rejected;
      default:
        return StatusTone.pending;
    }
  }

  static StatusStyle statusStyle(StatusTone tone, bool isDark) {
    switch (tone) {
      case StatusTone.approved:
        return StatusStyle(
          fg: isDark ? approvedDark : approvedLight,
          bg: isDark
              ? const Color(0xFF064E3B).withValues(alpha: 0.45)
              : const Color(0xFFECFDF5),
          outline: (isDark ? approvedDark : approvedLight).withValues(
            alpha: isDark ? 0.42 : 0.34,
          ),
          icon: Icons.check_circle_rounded,
          label: 'Approved',
        );
      case StatusTone.pending:
        return StatusStyle(
          fg: isDark ? pendingDark : pendingLight,
          bg: isDark
              ? const Color(0xFF78350F).withValues(alpha: 0.42)
              : const Color(0xFFFFFBEB),
          outline: (isDark ? pendingDark : pendingLight).withValues(
            alpha: isDark ? 0.42 : 0.34,
          ),
          icon: Icons.schedule_rounded,
          label: 'Pending review',
        );
      case StatusTone.rejected:
        return StatusStyle(
          fg: isDark ? rejectedDark : rejectedLight,
          bg: isDark
              ? const Color(0xFF7F1D1D).withValues(alpha: 0.42)
              : const Color(0xFFFEF2F2),
          outline: (isDark ? rejectedDark : rejectedLight).withValues(
            alpha: isDark ? 0.42 : 0.34,
          ),
          icon: Icons.cancel_rounded,
          label: 'Rejected',
        );
      case StatusTone.info:
        return StatusStyle(
          fg: brandOnSurface(isDark),
          bg: brandWash(isDark),
          outline: brand(isDark).withValues(alpha: isDark ? 0.42 : 0.30),
          icon: Icons.info_rounded,
          label: 'Info',
        );
      case StatusTone.neutral:
        return StatusStyle(
          fg: textSecondary(isDark),
          bg: sunken(isDark),
          outline: border(isDark),
          icon: Icons.remove_rounded,
          label: 'None',
        );
    }
  }

  // ── Decorations ───────────────────────────────────────────────────────────
  static BoxDecoration cardDecoration(
    bool isDark, {
    double radius = radiusLg,
    bool elevated = true,
    Color? accentBorder,
  }) {
    return BoxDecoration(
      color: surface(isDark),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: accentBorder ?? border(isDark)),
      boxShadow: elevated ? shadowSm(isDark) : null,
    );
  }

  // ── Typography ────────────────────────────────────────────────────────────
  // A real scale, declared once. `AppDesign.buildTheme` loses the Material font
  // sizes because its `TextTheme.copyWith` replaces whole `TextStyle`s without
  // restating `fontSize`; that is why the web screens ended up hand-setting 28
  // different sizes. This builds every role explicitly instead.
  //
  // Body floor is 12px. 11px exists only for uppercase, letter-spaced eyebrows.
  static TextTheme textTheme(bool isDark, String fontFamily) {
    final primary = textPrimary(isDark);
    final secondary = textSecondary(isDark);
    final muted = textMuted(isDark);

    return TextTheme(
      displaySmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 30,
        height: 1.2,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
        color: primary,
      ),
      headlineMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 26,
        height: 1.22,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
        color: primary,
      ),
      headlineSmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 22,
        height: 1.25,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        color: primary,
      ),
      titleLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 18,
        height: 1.3,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: primary,
      ),
      titleMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 15,
        height: 1.35,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.1,
        color: primary,
      ),
      titleSmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 13,
        height: 1.4,
        fontWeight: FontWeight.w700,
        color: primary,
      ),
      bodyLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 15,
        height: 1.5,
        fontWeight: FontWeight.w400,
        color: primary,
      ),
      bodyMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 13.5,
        height: 1.5,
        fontWeight: FontWeight.w400,
        color: secondary,
      ),
      bodySmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12,
        height: 1.5,
        fontWeight: FontWeight.w400,
        color: muted,
      ),
      labelLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 13,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: primary,
      ),
      labelMedium: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: secondary,
      ),
      // Uppercase eyebrow / section label only.
      labelSmall: TextStyle(
        fontFamily: fontFamily,
        fontSize: 11,
        height: 1.3,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.7,
        color: muted,
      ),
    );
  }

  /// Tabular figures so metric values and coordinate columns stop shifting width.
  static TextStyle tabular(TextStyle base) =>
      base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  // ── Theme ─────────────────────────────────────────────────────────────────
  static ThemeData buildTheme({
    required bool isDark,
    String fontFamily = 'Roboto',
  }) {
    final accent = brand(isDark);
    final text = textTheme(isDark, fontFamily);

    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: isDark ? Brightness.dark : Brightness.light,
      primary: accent,
      onPrimary: isDark ? const Color(0xFF06283D) : Colors.white,
      secondary: textSecondary(isDark),
      surface: surface(isDark),
      onSurface: textPrimary(isDark),
      error: isDark ? rejectedDark : rejectedLight,
      outline: border(isDark),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: isDark ? Brightness.dark : Brightness.light,
      fontFamily: fontFamily,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg(isDark),
      canvasColor: bg(isDark),
      textTheme: text,
      primaryTextTheme: text,
      focusColor: accent.withValues(alpha: 0.28),
      hoverColor: hover(isDark),
      dividerTheme: DividerThemeData(
        color: border(isDark),
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: textSecondary(isDark), size: iconMd),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: surface(isDark),
        foregroundColor: textPrimary(isDark),
        titleTextStyle: text.titleLarge,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surface(isDark),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: BorderSide(color: border(isDark)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: sunken(isDark),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: space3,
          vertical: space3,
        ),
        labelStyle: text.bodyMedium,
        floatingLabelStyle: text.labelMedium?.copyWith(
          color: brandOnSurface(isDark),
          fontWeight: FontWeight.w700,
        ),
        hintStyle: text.bodyMedium?.copyWith(color: textMuted(isDark)),
        helperStyle: text.bodySmall,
        errorStyle: text.bodySmall?.copyWith(color: danger(isDark)),
        prefixIconColor: textSecondary(isDark),
        suffixIconColor: textSecondary(isDark),
        border: _fieldBorder(border(isDark)),
        enabledBorder: _fieldBorder(border(isDark)),
        focusedBorder: _fieldBorder(accent, width: 2),
        errorBorder: _fieldBorder(danger(isDark)),
        focusedErrorBorder: _fieldBorder(danger(isDark), width: 2),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: border(isDark),
          disabledForegroundColor: textMuted(isDark),
          elevation: 0,
          minimumSize: const Size(0, minTarget),
          padding: const EdgeInsets.symmetric(horizontal: space4),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary(isDark),
          side: BorderSide(color: border(isDark)),
          minimumSize: const Size(0, minTarget),
          padding: const EdgeInsets.symmetric(horizontal: space4),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: brandOnSurface(isDark),
          minimumSize: const Size(0, minTarget),
          padding: const EdgeInsets.symmetric(horizontal: space3),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: textSecondary(isDark),
          minimumSize: const Size(minTarget, minTarget),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: border(isDark),
        circularTrackColor: Colors.transparent,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: sunken(isDark),
        selectedColor: brandWash(isDark),
        labelStyle: text.labelMedium,
        side: BorderSide(color: border(isDark)),
        padding: const EdgeInsets.symmetric(
          horizontal: space2,
          vertical: space1,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary(isDark),
        textColor: textPrimary(isDark),
        titleTextStyle: text.titleSmall,
        subtitleTextStyle: text.bodySmall,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: brandOnSurface(isDark),
        unselectedLabelColor: textSecondary(isDark),
        indicatorColor: accent,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? Colors.white : textMuted(isDark),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : border(isDark),
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        padding: const EdgeInsets.symmetric(
          horizontal: space2,
          vertical: space1 + 2,
        ),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(radiusSm),
        ),
        textStyle: text.bodySmall?.copyWith(color: Colors.white),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface(isDark),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusXl),
          side: BorderSide(color: border(isDark)),
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface(isDark),
        modalBackgroundColor: surface(isDark),
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? const Color(0xFF1E293B)
            : const Color(0xFF0F172A),
        contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
        actionTextColor: isDark
            ? const Color(0xFF7DD3FC)
            : const Color(0xFF93C5FD),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
        insetPadding: const EdgeInsets.all(space4),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface(isDark),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          side: BorderSide(color: border(isDark)),
        ),
        textStyle: text.labelMedium,
      ),
    );
  }

  static OutlineInputBorder _fieldBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(radiusSm),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  /// Neutral SnackBar. Status is carried by an icon plus text, never by colour
  /// alone, and never by an emoji.
  static SnackBar snack(
    String message, {
    required bool isDark,
    StatusTone tone = StatusTone.info,
  }) {
    final style = statusStyle(tone, isDark);
    return SnackBar(
      content: Row(
        children: [
          Icon(style.icon, size: iconSm, color: style.fg),
          const SizedBox(width: space2),
          Expanded(child: Text(message)),
        ],
      ),
      duration: const Duration(seconds: 4),
    );
  }
}
