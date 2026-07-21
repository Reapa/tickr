import 'package:flutter/material.dart';

/// Tickr design system — a sharp, dark, terminal-cool trading theme.
/// Green = up, red = down, everywhere and always. The signature is an
/// electric cyan-green paired with a blue, used as a gradient for brand moments.
abstract final class AppTheme {
  // ---- Core palette ---------------------------------------------------------
  static const Color up = Color(0xFF2BD98A); // brighter, punchier green
  static const Color down = Color(0xFFFF5A52); // vivid red
  static const Color accent = Color(0xFF4DA3FF); // blue
  static const Color brand = Color(0xFF3DE1C4); // signature cyan-green
  static const Color gold = Color(0xFFFFC94D); // prestige / rewards

  // ---- Surfaces (layered "panels") -----------------------------------------
  static const Color background = Color(0xFF080B12); // near-black, blue tint
  static const Color surface = Color(0xFF121722); // card
  static const Color surfaceHigh = Color(0xFF1A2130); // elevated / hover
  static Color get hairline => Colors.white.withValues(alpha: 0.07);

  // ---- Brand gradient -------------------------------------------------------
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
    colors: [accent, brand],
  );
  static const LinearGradient upGradient = LinearGradient(
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
    colors: [Color(0xFF1FA968), up],
  );

  // ---- Shape tokens ---------------------------------------------------------
  static const double radius = 14;
  static const double radiusSm = 10;

  /// Tabular figures for prices/numbers — digits align, the terminal feel.
  static const TextStyle number = TextStyle(
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static Color changeColor(num change) => change >= 0 ? up : down;

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: brand,
      brightness: Brightness.dark,
      surface: surface,
      primary: brand,
    );
    final base = ThemeData(
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      useMaterial3: true,
      fontFamily: 'Roboto',
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
          color: Colors.white,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: hairline),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: brand,
        unselectedLabelColor: Colors.grey.shade500,
        indicatorColor: brand,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle:
            const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
        unselectedLabelStyle:
            const TextStyle(fontWeight: FontWeight.w500, fontSize: 13.5),
        overlayColor: WidgetStatePropertyAll(brand.withValues(alpha: 0.06)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          textStyle:
              const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: brand,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 50),
          side: BorderSide(color: hairline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          textStyle:
              const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceHigh,
        side: BorderSide(color: hairline),
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: const BorderSide(color: brand, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: background,
        indicatorColor: brand.withValues(alpha: 0.16),
        elevation: 0,
        height: 64,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: states.contains(WidgetState.selected)
                  ? brand
                  : Colors.grey.shade500,
            )),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? brand
                  : Colors.grey.shade500,
            )),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: background,
        indicatorColor: brand.withValues(alpha: 0.16),
        selectedIconTheme: const IconThemeData(color: brand),
        selectedLabelTextStyle:
            const TextStyle(color: brand, fontWeight: FontWeight.w700),
        unselectedIconTheme: IconThemeData(color: Colors.grey.shade500),
      ),
      dividerTheme: DividerThemeData(color: hairline, space: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceHigh,
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: brand),
    );
  }
}
