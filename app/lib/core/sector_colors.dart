import 'package:flutter/material.dart';

/// One consistent color per sector, used everywhere a sector appears
/// (asset avatars, diversification bar, chips) so players build an
/// instant visual association.
abstract final class SectorColors {
  static const Map<String, Color> _colors = {
    'tech': Color(0xFF4DA3FF),
    'energy': Color(0xFFFFA726),
    'finance': Color(0xFF26C6DA),
    'consumer': Color(0xFFEC6EAD),
    'healthcare': Color(0xFF66BB6A),
    'commercial': Color(0xFF9575CD),
    'residential': Color(0xFFA1887F),
    'industrial': Color(0xFF90A4AE),
    'hospitality': Color(0xFFFFD54F),
    'private': Color(0xFFB0BEC5),
  };

  static Color of(String sector) =>
      _colors[sector] ??
      Colors.primaries[sector.hashCode.abs() % Colors.primaries.length];
}
