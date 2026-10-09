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
  static const Color textMutedLight = Color(0xFF94A3B8);

  static const Color textPrimaryDark = Color(0xFFF8FAFC);
  static const Color textSecondaryDark = Color(0xFF94A3B8);
  static const Color textMutedDark = Color(0xFF64748B);

  // Luminous Semantic Action & Severity Tokens
  static const Color accentLight = Color(0xFF0284C7); // Tactical Azure Sky
  static const Color accentDark = Color(0xFF00D2FF);  // Luminous Cyan / Precision Telemetry
  static const Color danger = Color(0xFFEF4444);      // High Severity Pothole (Vivid Red)
  static const Color warning = Color(0xFFF97316);     // Medium Severity Pothole (Vivid Orange)
  static const Color caution = Color(0xFFEAB308);     // Low Severity Pothole (Amber Yellow)
  static const Color success = Color(0xFF10B981);     // Approved / Verified / Safe (Emerald)

  // ── DPWH Road Distress Classification Engineering Tokens ─────────────────
  static const Color dpwhCode01 = Color(0xFFEF4444); // Pothole (Urgent 3-Day Fix)
  static const Color dpwhCode02 = Color(0xFFF97316); // Alligator Crack (High 3-Day Fix)
  static const Color dpwhCode05 = Color(0xFFEAB308); // Pavement Depression (30-Day Fix)
  static const Color dpwhCode12 = Color(0xFF38BDF8); // Longitudinal/Transverse Crack (Routine Sealant)

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

  static Color border(bool isDark) {
    if (AppSettings.instance.isBlackAndWhite) {
      return isDark ? const Color(0xFF444444) : const Color(0xFFCCCCCC);
    }
    return isDark ? borderDark : borderLight;
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

  // ── Reusable Component Decorations ──────────────────────────────────────
  static BoxDecoration cardDecoration({
    bool isDark = false,
    double radius = 8.0,
  }) {
    return BoxDecoration(
      color: surface(isDark),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: border(isDark), width: 1.0),
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
    final fillColor = isDark
        ? const Color(0xFF0F172A)
        : const Color(0xFFF8FAFC);

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: subtextColor, fontSize: 13),
      floatingLabelStyle: TextStyle(
        color: accent(isDark),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.auto,
      prefixIcon: Icon(icon, color: subtextColor, size: 20),
      suffixIcon: suffixIcon,
      fillColor: fillColor,
      filled: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: accent(isDark), width: 1.5),
      ),
    );
  }

  static ButtonStyle primaryButtonStyle({
    bool isDark = false,
    double borderRadius = 6.0,
  }) {
    return ElevatedButton.styleFrom(
      backgroundColor: accent(isDark),
      foregroundColor: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
  }

  static ButtonStyle outlinedButtonStyle({
    bool isDark = false,
    double borderRadius = 6.0,
  }) {
    return OutlinedButton.styleFrom(
      foregroundColor: textPrimary(isDark),
      side: BorderSide(color: border(isDark)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );
  }

  static ThemeData buildTheme({
    required bool isDark,
    String fontFamily = 'Roboto',
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent(isDark),
      brightness: isDark ? Brightness.dark : Brightness.light,
      primary: accent(isDark),
      secondary: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
      surface: surface(isDark),
      error: danger,
    );

    final baseTypography = isDark
        ? Typography.material2021().white
        : Typography.material2021().black;

    final themedText = baseTypography
        .apply(
          fontFamily: fontFamily,
          bodyColor: textPrimary(isDark),
          displayColor: textPrimary(isDark),
        )
        .copyWith(
          titleLarge: TextStyle(
            color: textPrimary(isDark),
            fontWeight: FontWeight.w800,
          ),
          titleMedium: TextStyle(
            color: textPrimary(isDark),
            fontWeight: FontWeight.w700,
          ),
          bodyMedium: TextStyle(color: textSecondary(isDark), height: 1.35),
          bodySmall: TextStyle(color: textMuted(isDark), height: 1.3),
          labelLarge: TextStyle(
            color: textPrimary(isDark),
            fontWeight: FontWeight.w700,
          ),
          labelMedium: TextStyle(color: textSecondary(isDark)),
          labelSmall: TextStyle(color: textMuted(isDark)),
        );

    final base = ThemeData(
      useMaterial3: true,
      brightness: isDark ? Brightness.dark : Brightness.light,
      fontFamily: fontFamily,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg(isDark),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: bg(isDark),
        foregroundColor: textPrimary(isDark),
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w800,
          color: textPrimary(isDark),
        ),
      ),
      cardTheme: cardTheme(isDark),
      inputDecorationTheme: inputTheme(isDark),
      elevatedButtonTheme: ElevatedButtonThemeData(
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
        selectedItemColor: accent(isDark),
        unselectedItemColor: textSecondary(isDark),
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface(isDark),
        indicatorColor: accent(isDark).withValues(alpha: 0.16),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? accent(isDark)
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
        labelColor: textPrimary(isDark),
        unselectedLabelColor: textSecondary(isDark),
        indicatorColor: accent(isDark),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : textMuted(isDark),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent(isDark)
              : border(isDark),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface(isDark),
        modalBackgroundColor: surface(isDark),
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? const Color(0xFF14181F)
            : const Color(0xFF111827),
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
      ),
      textTheme: themedText,
      primaryTextTheme: themedText,
    );

    return base.copyWith(
      chipTheme: ChipThemeData(
        backgroundColor: isDark
            ? const Color(0xFF111827)
            : const Color(0xFFF1F5F9),
        selectedColor: accent(isDark).withValues(alpha: 0.14),
        labelStyle: TextStyle(
          color: textPrimary(isDark),
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide(color: border(isDark)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface(isDark),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        titleTextStyle: TextStyle(
          color: textPrimary(isDark),
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
        contentTextStyle: TextStyle(color: textSecondary(isDark), fontSize: 14),
      ),
    );
  }

  static InputDecorationTheme inputTheme(bool isDark) {
    return InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF111827) : const Color(0xFFF8FAFC),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: textSecondary(isDark)),
      hintStyle: TextStyle(color: textMuted(isDark)),
      prefixIconColor: textSecondary(isDark),
      suffixIconColor: textSecondary(isDark),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border(isDark)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border(isDark)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: accent(isDark), width: 1.5),
      ),
    );
  }

  static CardThemeData cardTheme(bool isDark) {
    return CardThemeData(
      elevation: 0,
      color: surface(isDark),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: border(isDark)),
      ),
    );
  }
}
