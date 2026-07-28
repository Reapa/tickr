import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/json.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';

/// One reel symbol, with its published odds and payouts.
class SlotSymbol {
  const SlotSymbol({
    required this.code,
    required this.name,
    required this.pay3,
    required this.pay2,
    required this.chance,
  });

  factory SlotSymbol.fromJson(Map<String, dynamic> json) => SlotSymbol(
        code: json['code'] as String,
        name: json['name'] as String,
        pay3: jsonDouble(json['pay3']),
        pay2: jsonDouble(json['pay2']),
        chance: jsonDouble(json['chance']),
      );

  final String code;
  final String name;
  final double pay3;
  final double pay2;
  final double chance;

  /// A glyph per symbol. Icons rather than emoji — emoji render inconsistently
  /// across platforms and the owner has rejected them before.
  IconData get icon => switch (code) {
        'coin' => Icons.monetization_on,
        'chart' => Icons.show_chart,
        'bull' => Icons.trending_up,
        'bear' => Icons.trending_down,
        'gem' => Icons.diamond,
        'rocket' => Icons.rocket_launch,
        'seven' => Icons.stars,
        _ => Icons.help_outline,
      };

  Color get color => switch (code) {
        'coin' => const Color(0xFFB9863A),
        'chart' => const Color(0xFF6FA8C7),
        'bull' => AppTheme.up,
        'bear' => AppTheme.down,
        'gem' => const Color(0xFF5AC8E0),
        'rocket' => const Color(0xFFB06AE0),
        'seven' => AppTheme.gold,
        _ => Colors.grey,
      };
}

/// The published odds — payout table plus the exact return to player.
class SlotOdds {
  const SlotOdds({
    required this.rtp,
    required this.minBet,
    required this.maxBet,
    required this.symbols,
  });

  factory SlotOdds.fromJson(Map<String, dynamic> json) => SlotOdds(
        rtp: jsonDouble(json['rtp']),
        minBet: jsonDouble(json['min_bet']),
        maxBet: jsonDouble(json['max_bet']),
        symbols: ((json['symbols'] as List<dynamic>?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(SlotSymbol.fromJson)
            .toList(),
      );

  final double rtp;
  final double minBet;
  final double maxBet;
  final List<SlotSymbol> symbols;

  double get housePct => (1 - rtp) * 100;
}

/// The outcome of one spin. Everything here was decided on the server.
class SpinResult {
  const SpinResult({
    required this.status,
    this.reason,
    this.reels = const [],
    this.bet = 0,
    this.multiplier = 0,
    this.payout = 0,
    this.net = 0,
    this.kind = 'lose',
    this.symbolName,
  });

  factory SpinResult.fromJson(Map<String, dynamic> json) => SpinResult(
        status: json['status'] as String,
        reason: json['reason'] as String?,
        reels: ((json['reels'] as List<dynamic>?) ?? const []).cast<String>(),
        bet: jsonDouble(json['bet']),
        multiplier: jsonDouble(json['multiplier']),
        payout: jsonDouble(json['payout']),
        net: jsonDouble(json['net']),
        kind: (json['kind'] as String?) ?? 'lose',
        symbolName: json['symbol_name'] as String?,
      );

  final String status; // spun | rejected
  final String? reason;
  final List<String> reels;
  final double bet;
  final double multiplier;
  final double payout;
  final double net;
  final String kind; // jackpot | triple | pair | lose
  final String? symbolName;

  bool get isSpun => status == 'spun';
  bool get isWin => payout > 0;
  bool get isJackpot => kind == 'jackpot';
}

/// Lifetime arcade record. `netPnl` is the figure the tick moves off the
/// season track, so slots can never decide a season.
class ArcadeStats {
  const ArcadeStats({
    required this.netPnl,
    required this.spins,
    required this.wagered,
    required this.won,
    required this.biggestWin,
  });

  factory ArcadeStats.fromJson(Map<String, dynamic> json) => ArcadeStats(
        netPnl: jsonDouble(json['net_pnl']),
        spins: jsonInt(json['spins']),
        wagered: jsonDouble(json['wagered']),
        won: jsonDouble(json['won']),
        biggestWin: jsonDouble(json['biggest_win']),
      );

  final double netPnl;
  final int spins;
  final double wagered;
  final double won;
  final double biggestWin;

  static const empty = ArcadeStats(
      netPnl: 0, spins: 0, wagered: 0, won: 0, biggestWin: 0);
}

class SlotsRepository {
  SlotsRepository(this._client);

  final SupabaseClient _client;

  Future<SlotOdds> fetchOdds() async {
    final json = await _client.rpc<Map<String, dynamic>>('get_slot_odds');
    return SlotOdds.fromJson(json);
  }

  Future<SpinResult> spin(double bet) async {
    final json = await _client
        .rpc<Map<String, dynamic>>('spin_slots', params: {'p_bet': bet});
    return SpinResult.fromJson(json);
  }

  Future<ArcadeStats> fetchStats() async {
    final rows = await _client
        .from('user_arcade')
        .select('net_pnl, spins, wagered, won, biggest_win')
        .limit(1);
    if (rows.isEmpty) return ArcadeStats.empty;
    return ArcadeStats.fromJson(rows.first);
  }
}

final slotsRepositoryProvider = Provider<SlotsRepository>(
  (ref) => SlotsRepository(ref.watch(supabaseProvider)),
);

final slotOddsProvider = FutureProvider<SlotOdds>(
  (ref) => ref.watch(slotsRepositoryProvider).fetchOdds(),
);

final arcadeStatsProvider = FutureProvider<ArcadeStats>(
  (ref) => ref.watch(slotsRepositoryProvider).fetchStats(),
);

final slotSymbolsByCodeProvider = Provider<Map<String, SlotSymbol>>((ref) {
  final odds = ref.watch(slotOddsProvider).value;
  return {for (final s in odds?.symbols ?? const <SlotSymbol>[]) s.code: s};
});
