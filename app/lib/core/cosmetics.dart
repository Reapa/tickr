import 'package:flutter/material.dart';

import 'theme.dart';

/// Visual registry for cosmetics. The database owns the *catalog* (which codes
/// exist, their price, rarity, slot); this file owns how each one *renders*.
/// Codes here must match the seeded `cosmetics.code` values.

// ---------------------------------------------------------------------------
// Avatar frames — a gradient ring (and glow) drawn around a trader's avatar.
// ---------------------------------------------------------------------------
class FrameStyle {
  const FrameStyle(this.colors, {this.glow, this.width = 3});

  /// Sweep-gradient ring colours (wraps back to the first).
  final List<Color> colors;
  final Color? glow;
  final double width;
}

const _bronze = Color(0xFFB07A45);
const _silver = Color(0xFFC7D0DA);
const _gold = AppTheme.gold;
const _diamond = Color(0xFF7FE3FF);
const _platinum = Color(0xFFE5E4E2);

const Map<String, FrameStyle> _frames = {
  'frame_bronze': FrameStyle([_bronze, Color(0xFF7A5230)], glow: _bronze),
  'frame_silver': FrameStyle([_silver, Color(0xFF8A97A6)], glow: _silver),
  'frame_gold': FrameStyle([_gold, Color(0xFFB8860B)], glow: _gold, width: 3.5),
  'frame_emerald': FrameStyle([Color(0xFF2BD67B), Color(0xFF0B6B3A)], glow: Color(0xFF2BD67B)),
  'frame_ruby': FrameStyle([Color(0xFFFF4D6D), Color(0xFF8B0020)], glow: Color(0xFFFF4D6D)),
  'frame_neon': FrameStyle([Color(0xFF00F5D4), Color(0xFFF20089), Color(0xFF00F5D4)], glow: Color(0xFF00F5D4), width: 3.5),
  'frame_obsidian': FrameStyle([Color(0xFF20143A), Color(0xFF6A3FB5), Color(0xFF20143A)], glow: Color(0xFF6A3FB5)),
  'frame_diamond': FrameStyle([_diamond, Color(0xFF4AA6C7), Colors.white], glow: _diamond, width: 3.5),
  'frame_platinum': FrameStyle([_platinum, Color(0xFFA9B2BC), Colors.white], glow: _platinum, width: 3.5),
  'frame_flame': FrameStyle([Color(0xFFFFD200), Color(0xFFFF5E00), Color(0xFFD30000)], glow: Color(0xFFFF5E00), width: 4),
  'frame_holo': FrameStyle([Color(0xFFFF6EC7), Color(0xFF7873F5), Color(0xFF4ADEDE), Color(0xFF54F542), Color(0xFFFFD93D), Color(0xFFFF6EC7)], glow: Color(0xFF7873F5), width: 4),
  'frame_minimal': FrameStyle([Colors.white70, Colors.white24], width: 2),
  // Earned / season exclusives.
  'frame_season_1': FrameStyle([_gold, Color(0xFFFFF6C8), _gold], glow: _gold, width: 4),
  'frame_champion': FrameStyle([Color(0xFFFFE259), Color(0xFFFFA751), Color(0xFFFFE259)], glow: _gold, width: 4.5),
};

FrameStyle? frameStyle(String? code) => code == null ? null : _frames[code];

// ---------------------------------------------------------------------------
// Profile badges — a small emblem shown next to a trader's name.
// ---------------------------------------------------------------------------
const Map<String, String> _badges = {
  'badge_bull': '🐂',
  'badge_bear': '🐻',
  'badge_rocket': '🚀',
  'badge_moon': '🌙',
  'badge_star': '⭐',
  'badge_fire': '🔥',
  'badge_paper_hands': '🧻',
  'badge_diamond_hands': '💎',
  'badge_degen': '🎰',
  'badge_brain': '🧠',
  'badge_shark': '🦈',
  'badge_whale': '🐋',
  'badge_crown': '👑',
  'badge_goat': '🐐',
  'badge_founder': '🏛️',
};

String? badgeEmoji(String? code) => code == null ? null : _badges[code];

// ---------------------------------------------------------------------------
// Chart themes — candle/line palette for the price chart.
// ---------------------------------------------------------------------------
class ChartTheme {
  const ChartTheme({required this.up, required this.down, required this.line, this.grid});
  final Color up;
  final Color down;
  final Color line;
  final Color? grid;

  static const base = ChartTheme(up: AppTheme.up, down: AppTheme.down, line: AppTheme.brand);
}

const Map<String, ChartTheme> _chartThemes = {
  'chart_neon': ChartTheme(up: Color(0xFF00F5D4), down: Color(0xFFF20089), line: Color(0xFF9B5DE5), grid: Color(0x2200F5D4)),
  'chart_paper': ChartTheme(up: Color(0xFF3A6B35), down: Color(0xFF9B2915), line: Color(0xFF5C4B37), grid: Color(0x22FFFFFF)),
  'chart_matrix': ChartTheme(up: Color(0xFF39FF14), down: Color(0xFF127a0a), line: Color(0xFF39FF14), grid: Color(0x2239FF14)),
  'chart_sunset': ChartTheme(up: Color(0xFFFFB000), down: Color(0xFFC03A83), line: Color(0xFFFF6B6B), grid: Color(0x22FFB000)),
  'chart_ocean': ChartTheme(up: Color(0xFF2EC4B6), down: Color(0xFFE71D36), line: Color(0xFF4CC9F0), grid: Color(0x224CC9F0)),
  'chart_mono': ChartTheme(up: Color(0xFFE6E6E6), down: Color(0xFF8A8A8A), line: Colors.white, grid: Color(0x22FFFFFF)),
};

ChartTheme chartTheme(String? code) => _chartThemes[code] ?? ChartTheme.base;

// ---------------------------------------------------------------------------
// Ticker skins — styling for the always-on positions/finances bar.
// ---------------------------------------------------------------------------
class TickerSkin {
  const TickerSkin({this.background, this.text, this.accent, this.mono = false});
  final Color? background;
  final Color? text;
  final Color? accent;
  final bool mono; // monospace-style tabular emphasis

  static const base = TickerSkin();
}

const Map<String, TickerSkin> _tickerSkins = {
  'ticker_retro': TickerSkin(background: Color(0xFF031A05), text: Color(0xFF39FF14), accent: Color(0xFF39FF14), mono: true),
  'ticker_gold': TickerSkin(background: Color(0xFF1A1608), text: Color(0xFFFFD866), accent: _gold),
  'ticker_neon': TickerSkin(background: Color(0xFF0B0620), text: Color(0xFF00F5D4), accent: Color(0xFFF20089)),
  'ticker_mono': TickerSkin(background: Color(0xFF101012), text: Colors.white, accent: Colors.white70, mono: true),
};

TickerSkin tickerSkin(String? code) => _tickerSkins[code] ?? TickerSkin.base;

// ---------------------------------------------------------------------------
// Convenience readers over an `equipped` map (slot -> code).
// ---------------------------------------------------------------------------
FrameStyle? equippedFrame(Map<String, dynamic>? equipped) =>
    frameStyle(equipped?['avatar_frame'] as String?);

String? equippedBadge(Map<String, dynamic>? equipped) =>
    badgeEmoji(equipped?['profile_badge'] as String?);

ChartTheme equippedChartTheme(Map<String, dynamic>? equipped) =>
    chartTheme(equipped?['chart_theme'] as String?);

TickerSkin equippedTickerSkin(Map<String, dynamic>? equipped) =>
    tickerSkin(equipped?['ticker_skin'] as String?);
