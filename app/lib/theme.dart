import 'package:flutter/material.dart';

/// Terrastep design tokens — Blueprint Section 7.
/// Quiet surfaces, one deep-green action color, limited territory palette,
/// 8 dp spacing system, one type family, large outdoor-readable numbers.
class TSColors {
  static const action = Color(0xFF1B7A43); // deep green
  static const actionDark = Color(0xFF2FA35C);
  static const surfaceLight = Color(0xFFFAFAF7);
  static const surfaceDark = Color(0xFF101312);
  static const inkLight = Color(0xFF16181A);
  static const inkDark = Color(0xFFF2F3F0);
  static const mutedLight = Color(0xFF5C6660);
  static const mutedDark = Color(0xFF9AA5A0);

  /// Vetted kingdom palette (Blueprint Section 7) — distinguishable in both themes.
  static const kingdomPalette = <Color>[
    Color(0xFF1B7A43), // green
    Color(0xFF2563EB), // blue
    Color(0xFFD97706), // amber
    Color(0xFFDB2777), // rose
    Color(0xFF7C3AED), // violet
    Color(0xFF0891B2), // cyan
    Color(0xFF65A30D), // lime
    Color(0xFF9333EA), // purple
  ];

  static String hexOf(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

class TSTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: TSColors.action,
      brightness: brightness,
      primary: isDark ? TSColors.actionDark : TSColors.action,
      surface: isDark ? TSColors.surfaceDark : TSColors.surfaceLight,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: const TextTheme(
        // Big activity numbers readable outdoors (Blueprint Section 7).
        displayMedium: TextStyle(fontSize: 44, fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontSize: 16),
        bodyMedium: TextStyle(fontSize: 14),
        labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52), // >= 48 dp touch targets (Section 7)
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}

/// 8 dp spacing system (Blueprint Section 7).
class TS {
  static const s1 = 8.0;
  static const s2 = 16.0;
  static const s3 = 24.0;
  static const s4 = 32.0;
}
