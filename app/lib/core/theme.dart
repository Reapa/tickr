import 'package:flutter/material.dart';

/// A dark, terminal-inspired trading theme. Green = up, red = down,
/// everywhere and always.
abstract final class AppTheme {
  static const Color up = Color(0xFF26C281);
  static const Color down = Color(0xFFE84C3D);
  static const Color accent = Color(0xFF4DA3FF);

  /// Tickr signature (electric cyan-green) — seeds the Material color scheme.
  static const Color brand = Color(0xFF3DE1C4);
  static const Color surface = Color(0xFF12161F);
  static const Color background = Color(0xFF0A0D14);

  static ThemeData dark() {
    final base = ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: brand,
        brightness: Brightness.dark,
        surface: surface,
      ),
      scaffoldBackgroundColor: background,
      useMaterial3: true,
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: const CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: Colors.white.withValues(alpha: 0.06),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Color for a signed change value.
  static Color changeColor(num change) => change >= 0 ? up : down;
}
