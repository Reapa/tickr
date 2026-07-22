import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/json.dart';
import '../../../core/supabase_providers.dart';
import '../domain/asset.dart';
import '../domain/market_event.dart';

/// Read side of the market. Live prices arrive as Realtime inserts on
/// price_ticks (the server's public broadcast channel); this repository folds
/// them into the asset list so the UI just re-renders.
///
/// Column lists are explicit everywhere: the database only grants SELECT on
/// public columns (fair_value etc. are hidden), so `select *` would 401.
class MarketRepository {
  MarketRepository(this._client);

  final SupabaseClient _client;

  static const _assetColumns = 'id, symbol, name, class_id, sector, '
      'description, current_price, spread, is_active, market_hours, '
      'listed_at, updated_at';
  static const _eventColumns =
      'id, scope, asset_id, sector, headline, body, sentiment, starts_at, '
      'ends_at, is_major';

  Future<List<Asset>> fetchAssets() async {
    final rows = await _client
        .from('assets')
        .select(_assetColumns)
        .eq('is_active', true)
        .order('symbol', ascending: true);
    return rows.map(Asset.fromJson).toList();
  }

  Future<List<AssetClass>> fetchAssetClasses() async {
    final rows = await _client
        .from('asset_classes')
        .select()
        .order('sort_order', ascending: true);
    return rows.map(AssetClass.fromJson).toList();
  }

  Future<List<Mover>> fetchMovers() async {
    final rows = await _client
        .rpc<List<dynamic>>('get_movers', params: {'p_window_hours': 24});
    return rows.cast<Map<String, dynamic>>().map(Mover.fromJson).toList();
  }

  Future<List<PricePoint>> fetchPriceHistory(
    String assetId, {
    Duration window = const Duration(hours: 1),
  }) async {
    final since = DateTime.now().toUtc().subtract(window);
    final rows = await _client
        .from('price_ticks')
        .select('price, tick_at')
        .eq('asset_id', assetId)
        .gte('tick_at', since.toIso8601String())
        .order('tick_at', ascending: true);
    return rows.map(PricePoint.fromJson).toList();
  }

  /// Oldest tick price inside [window] — the reference for "change today".
  Future<double?> fetchOpeningPrice(
    String assetId, {
    Duration window = const Duration(hours: 24),
  }) async {
    final since = DateTime.now().toUtc().subtract(window);
    final rows = await _client
        .from('price_ticks')
        .select('price')
        .eq('asset_id', assetId)
        .gte('tick_at', since.toIso8601String())
        .order('tick_at', ascending: true)
        .limit(1);
    return rows.isEmpty ? null : jsonDouble(rows.first['price']);
  }

  /// Server-side OHLC candles for trader-style charts.
  Future<List<Candle>> fetchCandles(
    String assetId,
    int bucketSeconds, {
    int limit = 60,
  }) async {
    final rows = await _client.rpc<List<dynamic>>('get_candles', params: {
      'p_asset_id': assetId,
      'p_bucket_seconds': bucketSeconds,
      'p_limit': limit,
    });
    return rows
        .cast<Map<String, dynamic>>()
        .map(Candle.fromJson)
        .toList();
  }

  /// The public earnings calendar: upcoming, not-yet-resolved announcements,
  /// soonest first. Outcome columns aren't granted, so we never see the result.
  Future<List<ScheduledEvent>> fetchUpcomingEvents({int limit = 20}) async {
    final rows = await _client
        .from('scheduled_events')
        .select('id, asset_id, kind, headline, quarter, resolves_at, status')
        .eq('status', 'scheduled')
        .order('resolves_at', ascending: true)
        .limit(limit);
    return rows.map(ScheduledEvent.fromJson).toList();
  }

  Future<List<MarketEvent>> fetchEvents({int limit = 50}) async {
    final rows = await _client
        .from('market_events')
        .select(_eventColumns)
        .order('starts_at', ascending: false)
        .limit(limit);
    return rows.map(MarketEvent.fromJson).toList();
  }

  /// Asset list that stays current: initial fetch + live price-tick folds.
  ///
  /// A tick advances ~30 assets at once, firing ~30 Realtime inserts in a
  /// burst. Emitting per insert would rebuild the whole list ~30× every cycle
  /// (the source of market-tab jank), so bursts are coalesced into one emit.
  Stream<List<Asset>> watchAssets() {
    final controller = StreamController<List<Asset>>();
    final byId = <String, Asset>{};
    RealtimeChannel? channel;
    Timer? flush;

    void emit() {
      final list = byId.values.toList()
        ..sort((a, b) => a.symbol.compareTo(b.symbol));
      controller.add(list);
    }

    void scheduleEmit() {
      flush ??= Timer(const Duration(milliseconds: 120), () {
        flush = null;
        emit();
      });
    }

    controller.onListen = () async {
      try {
        for (final asset in await fetchAssets()) {
          byId[asset.id] = asset;
        }
        emit();
      } catch (error, stack) {
        controller.addError(error, stack);
        return;
      }
      channel = _client
          .channel('public:price_ticks')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'price_ticks',
            callback: (payload) {
              final record = payload.newRecord;
              final assetId = record['asset_id'] as String?;
              final existing = assetId == null ? null : byId[assetId];
              if (existing == null) return;
              byId[assetId!] = existing.withPrice(jsonDouble(record['price']));
              scheduleEmit();
            },
          )
          .subscribe();
    };
    controller.onCancel = () {
      flush?.cancel();
      if (channel != null) _client.removeChannel(channel!);
    };
    return controller.stream;
  }

  /// News feed that stays current: initial fetch + live event inserts, with a
  /// periodic re-fetch as a backstop. Realtime alone can silently stall on
  /// mobile (a backgrounded tab or a locked phone suspends the WebSocket, and
  /// postgres_changes never replays the gap), which froze the feed until a
  /// manual refresh; the 30s resync guarantees it self-heals.
  Stream<List<MarketEvent>> watchEvents({int limit = 50}) {
    final controller = StreamController<List<MarketEvent>>();
    var events = <MarketEvent>[];
    RealtimeChannel? channel;
    Timer? resync;

    Future<void> refetch() async {
      try {
        events = await fetchEvents(limit: limit);
        controller.add(events);
      } catch (_) {
        // Transient failure (e.g. offline); the next resync will reconcile.
      }
    }

    controller.onListen = () async {
      try {
        events = await fetchEvents(limit: limit);
        controller.add(events);
      } catch (error, stack) {
        controller.addError(error, stack);
        return;
      }
      channel = _client
          .channel('public:market_events')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'market_events',
            callback: (payload) {
              // Realtime sends only client-visible rows, but the payload has
              // hidden columns stripped — reparse defensively.
              try {
                final event = MarketEvent.fromJson(payload.newRecord);
                events = [event, ...events].take(limit).toList();
                controller.add(events);
              } catch (_) {
                // Ignore malformed payloads; next fetch will reconcile.
              }
            },
          )
          .subscribe();
      resync = Timer.periodic(const Duration(seconds: 30), (_) => refetch());
    };
    controller.onCancel = () {
      resync?.cancel();
      if (channel != null) _client.removeChannel(channel!);
    };
    return controller.stream;
  }
}

final marketRepositoryProvider = Provider<MarketRepository>(
  (ref) => MarketRepository(ref.watch(supabaseProvider)),
);

/// Live asset list (prices update every tick).
final assetsProvider = StreamProvider<List<Asset>>(
  (ref) => ref.watch(marketRepositoryProvider).watchAssets(),
);

/// Convenience lookup: asset-id -> live price.
final livePricesProvider = Provider<Map<String, double>>((ref) {
  final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
  return {for (final a in assets) a.id: a.currentPrice};
});

/// Live news feed.
final marketEventsProvider = StreamProvider<List<MarketEvent>>(
  (ref) => ref.watch(marketRepositoryProvider).watchEvents(),
);

/// The earnings calendar (upcoming announcements), refreshed every 5s so newly
/// scheduled events appear and resolved ones drop off. The per-second countdown
/// is driven by the widgets themselves, not by refetching.
final upcomingEventsProvider =
    FutureProvider.autoDispose<List<ScheduledEvent>>((ref) {
  final timer = Timer(const Duration(seconds: 5), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(marketRepositoryProvider).fetchUpcomingEvents();
});

final assetClassesProvider = FutureProvider<List<AssetClass>>(
  (ref) => ref.watch(marketRepositoryProvider).fetchAssetClasses(),
);

/// Top movers, refreshed every 20s so the strip stays lively.
final moversProvider = FutureProvider.autoDispose<List<Mover>>((ref) {
  final timer = Timer(const Duration(seconds: 20), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(marketRepositoryProvider).fetchMovers();
});

/// OHLC candles for one asset at one bucket size, timer-refreshed so the
/// forming candle stays current (same decoupling rationale as history below).
final candlesProvider = FutureProvider.autoDispose
    .family<List<Candle>, (String, int)>((ref, key) {
  final timer = Timer(const Duration(seconds: 10), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  // Fetch a deep history so the chart can be scrolled/zoomed back in time.
  return ref.watch(marketRepositoryProvider).fetchCandles(key.$1, key.$2, limit: 200);
});

/// 24h-ago reference price per asset. Fetched once and cached (unlike the
/// live price), so change badges don't refetch on every tick.
final openingPriceProvider = FutureProvider.family<double?, String>(
  (ref, assetId) =>
      ref.watch(marketRepositoryProvider).fetchOpeningPrice(assetId),
);

/// Price history for one asset. Refreshes on a timer rather than by watching
/// the live price: coupling a FutureProvider to the tick stream via select()
/// can invalidate mid-build when a tab's TickerMode resumes ("setState during
/// build"). The chart appends the live price itself for tick-level freshness.
final priceHistoryProvider = FutureProvider.autoDispose
    .family<List<PricePoint>, String>((ref, assetId) {
  final timer = Timer(const Duration(seconds: 15), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(marketRepositoryProvider).fetchPriceHistory(assetId);
});
