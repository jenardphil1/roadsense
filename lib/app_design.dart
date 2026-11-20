import 'package:flutter/material.dart';
import 'app_settings.dart';

/// RoadSense AI — Enterprise Clean UI Design System
/// Flat, structured, high-legibility palette inspired by Linear, Supabase, and Notion.
class AppDesign {
  // ── Color Tokens (UI/UX Pro Max Telemetry & GIS Palette) ───────────────────
  static const Color bgLight = Color(0xFFF8FAFC);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color borderLight = Color(0xFFE2E8F0);

  // Deep Obsidian Navy for high-contrast map overlays & telemetry HUD
  static const Color bgDark = Color(0xFF080D1A);
  static const Color surfaceDark = Color(0xFF0F172A);
  static const Color borderDark = Color(0xFF1E293B);

  // High-Legibility Typography Contrast
  static const Color textPrimaryLight = Color(0xFF0F172A);
  static const Color textSecondaryLight = Color(0xFF475569);
  static const Color textMutedLight = Color(0xFF64748B);

  static const Color textPrimaryDark = Color(0xFFF8FAFC);
  static const Color textSecondaryDark = Color(0xFF94A3B8);
  static const Color textMutedDark = Color(0xFF94A3B8);

  // Interactive Brand Color (Unified with WebDesign #2563EB / #60A5FA)
  static const Color brand = Color(0xFF2563EB);
  static const Color brandHover = Color(0xFF1D4ED8);
  static const Color accentLight = Color(0xFF2563EB); // 5.17:1 on white
  static const Color accentDark = Color(0xFF60A5FA); // 6.7:1 on #0F172A
  static const Color danger = Color(0xFFEF4444); // High Severity Pothole
  static const Color warning = Color(0xFFF97316); // Medium Severity Pothole
  static const Color caution = Color(0xFFEAB308); // Low Severity Pothole
  static const Color success = Color(0xFF10B981); // Approved / Verified / Safe

  // Spacing Scale (4pt rhythm matching WebDesign)
  static const double s4 = 4.0;
  static const double s8 = 8.0;
  static const double s12 = 12.0;
  static const double s16 = 16.0;
  static const double s20 = 20.0;
  static const double s24 = 24.0;
  static const double s32 = 32.0;

  // Radius Scale matching WebDesign
  static const double radiusSm = 6.0;
  static const double radiusMd = 10.0;
  static const double radiusLg = 14.0;
  static const double radiusXl = 20.0;
  static const double radiusPill = 999.0;

  // ── DPWH Road Distress Classification Engineering Tokens ─────────────────
  static const Color dpwhCode01 = Color(
    0xFFEF4444,
  ); // Pothole (Urgent 3-Day Fix)
  static const Color dpwhCode02 = Color(
    0xFFF97316,
  ); // Alligator Crack (High 3-Day Fix)
  static const Color dpwhCode05 = Color(
    0xFFEAB308,
  ); // Pavement Depression (30-Day Fix)
  static const Color dpwhCode12 = Color(
    0xFF38BDF8,
  ); // Longitudinal/Transverse Crack (Routine Sealant)

  // ── Context Helpers (With High-Contrast Black & White Support) ────────────
  static Color bg(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    }
    return isDark ? bgDark : bgLight;
  }

  static Color surface(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFF121212) : const Color(0xFFF6F6F6);
    }
    return isDark ? surfaceDark : surfaceLight;
  }

  static Color sunken(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFF0A0A0A) : const Color(0xFFECECEC);
    }
    return isDark ? const Color(0xFF0D1524) : const Color(0xFFF1F5F9);
  }

  static Color hover(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFF1F1F1F) : const Color(0xFFE5E5E5);
    }
    return isDark ? const Color(0xFF172033) : const Color(0xFFF8FAFC);
  }

  static Color border(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFF444444) : const Color(0xFFCCCCCC);
    }
    return isDark ? borderDark : borderLight;
  }

  static Color borderStrong(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFF666666) : const Color(0xFF999999);
    }
    return isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);
  }

  static Color brandWash(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark
          ? Colors.white.withValues(alpha: 0.14)
          : Colors.black.withValues(alpha: 0.08);
    }
    return isDark ? brand.withValues(alpha: 0.18) : const Color(0xFFEFF6FF);
  }

  static Color brandBorder(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFF888888) : const Color(0xFF555555);
    }
    return isDark
        ? const Color(0xFF3B82F6).withValues(alpha: 0.45)
        : const Color(0xFFBFDBFE);
  }

  static Color textPrimary(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
    }
    return isDark ? textPrimaryDark : textPrimaryLight;
  }

  static Color textSecondary(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFFAAAAAA) : const Color(0xFF555555);
    }
    return isDark ? textSecondaryDark : textSecondaryLight;
  }

  static Color textMuted(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFF777777) : const Color(0xFF888888);
    }
    return isDark ? textMutedDark : textMutedLight;
  }

  static Color accent(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
    }
    return isDark ? accentDark : accentLight;
  }

  static List<BoxShadow> shadowSm(bool isDark) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.05),
      blurRadius: 4,
      offset: const Offset(0, 1),
    ),
  ];

  static List<BoxShadow> shadowMd(bool isDark) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.36 : 0.08),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ];

  static TextStyle tabular(TextStyle? base) => (base ?? const TextStyle())
      .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  // ── Reusable Component Decorations ──────────────────────────────────────
  static BoxDecoration cardDecoration({
    bool isDark = false,
    double radius = radiusLg,
    bool elevated = false,
    Color? fill,
    Color? accentBorder,
  }) {
    return BoxDecoration(
      color: fill ?? surface(isDark),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: accentBorder ?? border(isDark), width: 1.0),
      boxShadow: elevated ? shadowSm(isDark) : null,
    );
  }

  static InputDecoration inputDecoration({
    required String label,
    required IconData icon,
    Widget? suffixIcon,
    bool isDark = false,
  }) {
    final subtextColor = textSecondary(isDark);
    final borderColor = border(isDark);
    final fillColor = sunken(isDark);

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: subtextColor, fontSize: 13.5),
      floatingLabelStyle: TextStyle(
        color: accent(isDark),
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.auto,
      prefixIcon: Icon(icon, color: subtextColor, size: 20),
      suffixIcon: suffixIcon,
      fillColor: fillColor,
      filled: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: BorderSide(color: borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: BorderSide(color: accent(isDark), width: 1.8),
      ),
    );
  }

  static ButtonStyle primaryButtonStyle({
    bool isDark = false,
    double borderRadius = radiusMd,
  }) {
    return ElevatedButton.styleFrom(
      backgroundColor: AppSettings.instance.isBlackAndWhite
          ? accent(isDark)
          : brand,
      foregroundColor: AppSettings.instance.isBlackAndWhite && isDark
          ? Colors.black
          : Colors.white,
      elevation: 0,
      minimumSize: const Size(64, 48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    );
  }

  static ButtonStyle outlinedButtonStyle({
    bool isDark = false,
    double borderRadius = radiusMd,
  }) {
    return OutlinedButton.styleFrom(
      foregroundColor: textPrimary(isDark),
      side: BorderSide(color: border(isDark)),
      minimumSize: const Size(64, 48),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
  }

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
        fontSize: 13.5,
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
        height: 1.45,
        fontWeight: FontWeight.w400,
        color: muted,
      ),
      labelLarge: TextStyle(
        fontFamily: fontFamily,
        fontSize: 13.5,
        height: 1.2,
        fontWeight: FontWeight.w700,
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

  static ThemeData buildTheme({
    required bool isDark,
    String fontFamily = 'Roboto',
  }) {
    final activeAccent = accent(isDark);
    final scheme = ColorScheme.fromSeed(
      seedColor: activeAccent,
      brightness: isDark ? Brightness.dark : Brightness.light,
      primary: activeAccent,
      onPrimary: Colors.white,
      secondary: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
      surface: surface(isDark),
      onSurface: textPrimary(isDark),
      error: danger,
    );

    final themedText = textTheme(isDark, fontFamily);

    final base = ThemeData(
      useMaterial3: true,
      brightness: isDark ? Brightness.dark : Brightness.light,
      fontFamily: fontFamily,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg(isDark),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: surface(isDark),
        foregroundColor: textPrimary(isDark),
        titleTextStyle: themedText.titleLarge,
      ),
      cardTheme: cardTheme(isDark),
      inputDecorationTheme: inputTheme(isDark),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: primaryButtonStyle(isDark: isDark),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: primaryButtonStyle(isDark: isDark),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: outlinedButtonStyle(isDark: isDark),
      ),
      dividerTheme: DividerThemeData(color: border(isDark), thickness: 1),
      iconTheme: IconThemeData(color: textSecondary(isDark)),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary(isDark),
        textColor: textPrimary(isDark),
        titleTextStyle: themedText.titleMedium,
        subtitleTextStyle: themedText.bodySmall,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surface(isDark),
        selectedItemColor: activeAccent,
        unselectedItemColor: textSecondary(isDark),
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface(isDark),
        indicatorColor: brandWash(isDark),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? activeAccent
                : textSecondary(isDark),
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? textPrimary(isDark)
                : textSecondary(isDark),
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: activeAccent,
        unselectedLabelColor: textSecondary(isDark),
        indicatorColor: activeAccent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : textMuted(isDark),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? (AppSettings.instance.isBlackAndWhite ? activeAccent : brand)
              : border(isDark),
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
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
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),
      textTheme: themedText,
      primaryTextTheme: themedText,
    );

    return base.copyWith(
      chipTheme: ChipThemeData(
        backgroundColor: sunken(isDark),
        selectedColor: brandWash(isDark),
        labelStyle: TextStyle(
          color: textPrimary(isDark),
          fontWeight: FontWeight.w600,
          fontSize: 12.5,
        ),
        side: BorderSide(color: border(isDark)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface(isDark),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusXl),
          side: BorderSide(color: border(isDark)),
        ),
        titleTextStyle: themedText.titleLarge,
        contentTextStyle: themedText.bodyMedium,
      ),
    );
  }

  static InputDecorationTheme inputTheme(bool isDark) {
    return InputDecorationTheme(
      filled: true,
      fillColor: sunken(isDark),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: textSecondary(isDark)),
      hintStyle: TextStyle(color: textMuted(isDark)),
      prefixIconColor: textSecondary(isDark),
      suffixIconColor: textSecondary(isDark),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: BorderSide(color: border(isDark)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: BorderSide(color: border(isDark)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: BorderSide(color: accent(isDark), width: 1.8),
      ),
    );
  }

  static CardThemeData cardTheme(bool isDark) {
    return CardThemeData(
      elevation: 0,
      color: surface(isDark),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
        side: BorderSide(color: border(isDark)),
      ),
    );
  }
}
