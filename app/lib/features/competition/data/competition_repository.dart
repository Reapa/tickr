import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/json.dart';
import '../../../core/supabase_providers.dart';

class LeaderboardEntry {
  const LeaderboardEntry({
    required this.userId,
    required this.displayName,
    required this.value,
    required this.level,
    required this.rank,
    this.equipped = const {},
  });

  final String userId;
  final String displayName;

  /// Net worth for the global/friends boards; % return for season boards.
  final double value;
  final int level;
  final int rank;
  final Map<String, dynamic> equipped;
}

class Season {
  const Season({
    required this.id,
    required this.number,
    required this.name,
    required this.startsAt,
    required this.endsAt,
  });

  factory Season.fromJson(Map<String, dynamic> json) => Season(
        id: json['id'] as String,
        number: jsonInt(json['number']),
        name: json['name'] as String,
        startsAt: jsonDate(json['starts_at']),
        endsAt: jsonDate(json['ends_at']),
      );

  final String id;
  final int number;
  final String name;
  final DateTime startsAt;
  final DateTime endsAt;

  Duration get remaining {
    final left = endsAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }
}

class Challenge {
  const Challenge({
    required this.id,
    required this.challengerId,
    required this.challengeeId,
    required this.duration,
    required this.status,
    required this.endsAt,
    required this.challengerReturn,
    required this.challengeeReturn,
    required this.challengerStartNw,
    required this.challengeeStartNw,
    required this.winnerId,
    required this.createdAt,
  });

  factory Challenge.fromJson(Map<String, dynamic> json) => Challenge(
        id: json['id'] as String,
        challengerId: json['challenger_id'] as String,
        challengeeId: json['challengee_id'] as String,
        duration: json['duration'] as String,
        status: json['status'] as String,
        endsAt: json['ends_at'] == null ? null : jsonDate(json['ends_at']),
        challengerReturn: json['challenger_return'] == null
            ? null
            : jsonDouble(json['challenger_return']),
        challengeeReturn: json['challengee_return'] == null
            ? null
            : jsonDouble(json['challengee_return']),
        challengerStartNw: json['challenger_start_nw'] == null
            ? null
            : jsonDouble(json['challenger_start_nw']),
        challengeeStartNw: json['challengee_start_nw'] == null
            ? null
            : jsonDouble(json['challengee_start_nw']),
        winnerId: json['winner_id'] as String?,
        createdAt: jsonDate(json['created_at']),
      );

  final String id;
  final String challengerId;
  final String challengeeId;
  final String duration;
  final String status;
  final DateTime? endsAt;
  final double? challengerReturn;
  final double? challengeeReturn;
  final double? challengerStartNw;
  final double? challengeeStartNw;
  final String? winnerId;
  final DateTime createdAt;

  String opponentId(String me) =>
      challengerId == me ? challengeeId : challengerId;

  double? myStartNw(String me) =>
      challengerId == me ? challengerStartNw : challengeeStartNw;

  bool isIncomingFor(String me) => status == 'pending' && challengeeId == me;
}

/// All three competition modes: persistent global/friends leaderboards,
/// resetting seasons ranked by % return, and head-to-head challenges.
class CompetitionRepository {
  CompetitionRepository(this._client);

  final SupabaseClient _client;

  Future<List<LeaderboardEntry>> fetchGlobalLeaderboard({
    int limit = 100,
  }) async {
    final rows = await _client
        .from('leaderboard')
        .select()
        .order('rank', ascending: true)
        .limit(limit);
    return rows
        .map((row) => LeaderboardEntry(
              userId: row['user_id'] as String,
              displayName: row['display_name'] as String,
              value: jsonDouble(row['net_worth']),
              level: jsonInt(row['level'], 1),
              rank: jsonInt(row['rank']),
              equipped:
                  (row['equipped'] as Map<String, dynamic>?) ?? const {},
            ))
        .toList();
  }

  Future<List<LeaderboardEntry>> fetchFriendsLeaderboard() async {
    final rows = await _client
        .rpc<List<dynamic>>('get_friends_leaderboard')
        .then((rows) => rows.cast<Map<String, dynamic>>());
    return rows
        .map((row) => LeaderboardEntry(
              userId: row['user_id'] as String,
              displayName: row['display_name'] as String,
              value: jsonDouble(row['net_worth']),
              level: jsonInt(row['level'], 1),
              rank: jsonInt(row['rank']),
              equipped:
                  (row['equipped'] as Map<String, dynamic>?) ?? const {},
            ))
        .toList();
  }

  Future<Season?> fetchActiveSeason() async {
    final rows = await _client
        .from('seasons')
        .select('id, number, name, starts_at, ends_at')
        .eq('status', 'active')
        .order('number', ascending: false)
        .limit(1);
    return rows.isEmpty ? null : Season.fromJson(rows.first);
  }

  Future<List<LeaderboardEntry>> fetchSeasonLeaderboard(
    String seasonId, {
    int limit = 100,
  }) async {
    final rows = await _client
        .from('season_leaderboard')
        .select()
        .eq('season_id', seasonId)
        .order('rank', ascending: true)
        .limit(limit);
    return rows
        .map((row) => LeaderboardEntry(
              userId: row['user_id'] as String,
              displayName: row['display_name'] as String,
              value: jsonDouble(row['pct_return']),
              level: jsonInt(row['level'], 1),
              rank: jsonInt(row['rank']),
              equipped:
                  (row['equipped'] as Map<String, dynamic>?) ?? const {},
            ))
        .toList();
  }

  Future<List<Challenge>> fetchChallenges() async {
    final rows = await _client
        .from('friend_challenges')
        .select()
        .order('created_at', ascending: false)
        .limit(30);
    return rows.map(Challenge.fromJson).toList();
  }

  /// Challenge list that refetches whenever any of the player's challenges
  /// change (accepts, resolutions from the tick, new incoming challenges).
  Stream<List<Challenge>> watchChallenges() {
    final controller = StreamController<List<Challenge>>();
    RealtimeChannel? channel;
    Timer? debounce;

    Future<void> refresh() async {
      try {
        controller.add(await fetchChallenges());
      } catch (error, stack) {
        controller.addError(error, stack);
      }
    }

    controller.onListen = () {
      refresh();
      channel = _client
          .channel('public:friend_challenges')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'friend_challenges',
            callback: (_) {
              debounce?.cancel();
              debounce = Timer(const Duration(milliseconds: 300), refresh);
            },
          )
          .subscribe();
    };
    controller.onCancel = () {
      debounce?.cancel();
      if (channel != null) _client.removeChannel(channel!);
    };
    return controller.stream;
  }

  Future<Map<String, dynamic>> createChallenge(
    String opponentId,
    String duration,
  ) =>
      _client.rpc<Map<String, dynamic>>('create_friend_challenge', params: {
        'p_opponent': opponentId,
        'p_duration': duration,
      });

  Future<Map<String, dynamic>> respondChallenge(
    String challengeId,
    bool accept,
  ) =>
      _client.rpc<Map<String, dynamic>>('respond_friend_challenge', params: {
        'p_challenge_id': challengeId,
        'p_accept': accept,
      });

  /// The player's most recent unseen closed-season result, or null. Claiming
  /// marks it seen server-side, so it only ever surfaces once.
  Future<SeasonResult?> claimSeasonResult() async {
    final json =
        await _client.rpc<Map<String, dynamic>>('claim_season_result');
    if (json['status'] != 'result') return null;
    return SeasonResult.fromJson(json);
  }

  Future<RankSnapshot?> fetchRankSnapshot() async {
    final json = await _client.rpc<Map<String, dynamic>>('my_rank_snapshot');
    if (json['rank'] == null) return null;
    return RankSnapshot(
        rank: jsonInt(json['rank']), aheadOf: json['ahead_of'] as String?);
  }

  Future<List<ActivityItem>> fetchActivity({int limit = 30}) async {
    final rows = await _client
        .rpc<List<dynamic>>('get_recent_activity', params: {'p_limit': limit});
    return rows.cast<Map<String, dynamic>>().map(ActivityItem.fromJson).toList();
  }
}

/// A player's final standing in a season that just closed — for the reveal.
class SeasonResult {
  const SeasonResult({
    required this.seasonNumber,
    required this.seasonName,
    required this.rank,
    required this.players,
    required this.pctReturn,
    required this.top10,
    required this.rewardGems,
    required this.rewardCash,
    this.rewardCosmetic,
  });

  factory SeasonResult.fromJson(Map<String, dynamic> json) => SeasonResult(
        seasonNumber: jsonInt(json['season_number']),
        seasonName: json['season_name'] as String,
        rank: jsonInt(json['rank']),
        players: jsonInt(json['players']),
        pctReturn: jsonDouble(json['pct_return']),
        top10: json['top10'] as bool? ?? false,
        rewardGems: jsonInt(json['reward_gems']),
        rewardCash: jsonInt(json['reward_cash']),
        rewardCosmetic: json['reward_cosmetic'] as String?,
      );

  final int seasonNumber;
  final String seasonName;
  final int rank;
  final int players;
  final double pctReturn;
  final bool top10;
  final int rewardGems;
  final int rewardCash;
  final String? rewardCosmetic;

  /// Rank as a top-fraction (0.05 = top 5%).
  double get percentile => players <= 0 ? 1 : rank / players;
  bool get isPodium => rank <= 3;
}

/// The caller's global rank + who sits one place below (for overtake toasts).
class RankSnapshot {
  const RankSnapshot({required this.rank, this.aheadOf});

  final int rank;
  final String? aheadOf;
}

/// A notable move from the public activity feed.
class ActivityItem {
  const ActivityItem({
    required this.at,
    required this.trader,
    required this.symbol,
    required this.kind,
    required this.side,
    required this.notional,
    required this.leverage,
    this.realizedPnl,
  });

  factory ActivityItem.fromJson(Map<String, dynamic> json) => ActivityItem(
        at: jsonDate(json['at']),
        trader: json['trader'] as String,
        symbol: json['symbol'] as String,
        kind: json['kind'] as String, // spot | leverage
        side: json['side'] as String,
        notional: jsonDouble(json['notional']),
        leverage: json['leverage'] == null ? null : jsonInt(json['leverage']),
        realizedPnl: json['realized_pnl'] == null
            ? null
            : jsonDouble(json['realized_pnl']),
      );

  final DateTime at;
  final String trader;
  final String symbol;
  final String kind;
  final String side;
  final double notional;
  final int? leverage;

  /// Cash profit (+) / loss (−) if this activity closed a spot position.
  final double? realizedPnl;

  bool get isLeverage => kind == 'leverage';
  bool get isBuySide => side == 'buy' || side == 'long';
  bool get isRealizedClose => !isLeverage && side == 'sell' && realizedPnl != null;
}

final competitionRepositoryProvider = Provider<CompetitionRepository>(
  (ref) => CompetitionRepository(ref.watch(supabaseProvider)),
);

final globalLeaderboardProvider = FutureProvider<List<LeaderboardEntry>>(
  (ref) => ref.watch(competitionRepositoryProvider).fetchGlobalLeaderboard(),
);

final friendsLeaderboardProvider = FutureProvider<List<LeaderboardEntry>>(
  (ref) => ref.watch(competitionRepositoryProvider).fetchFriendsLeaderboard(),
);

final activeSeasonProvider = FutureProvider<Season?>(
  (ref) => ref.watch(competitionRepositoryProvider).fetchActiveSeason(),
);

/// Claims (once) the player's latest closed-season result on app start. Null
/// when there is nothing new to reveal.
final seasonResultProvider = FutureProvider<SeasonResult?>(
  (ref) => ref.watch(competitionRepositoryProvider).claimSeasonResult(),
);

/// The player's global rank, polled every 25s so an overtake can be surfaced.
final rankSnapshotProvider =
    FutureProvider.autoDispose<RankSnapshot?>((ref) {
  final timer = Timer(const Duration(seconds: 25), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(competitionRepositoryProvider).fetchRankSnapshot();
});

/// Public activity feed, refreshed every 8s so it feels live.
final activityFeedProvider =
    FutureProvider.autoDispose<List<ActivityItem>>((ref) {
  final timer = Timer(const Duration(seconds: 8), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(competitionRepositoryProvider).fetchActivity();
});

final seasonLeaderboardProvider =
    FutureProvider.family<List<LeaderboardEntry>, String>(
  (ref, seasonId) =>
      ref.watch(competitionRepositoryProvider).fetchSeasonLeaderboard(seasonId),
);

final challengesProvider = StreamProvider<List<Challenge>>(
  (ref) => ref.watch(competitionRepositoryProvider).watchChallenges(),
);
