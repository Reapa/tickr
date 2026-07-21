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
      'description, current_price, spread, is_active, listed_at, updated_at';
  static const _eventColumns =
      'id, scope, asset_id, sector, headline, body, sentiment, starts_at, ends_at';

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

  Future<List<MarketEvent>> fetchEvents({int limit = 50}) async {
    final rows = await _client
        .from('market_events')
        .select(_eventColumns)
        .order('starts_at', ascending: false)
        .limit(limit);
    return rows.map(MarketEvent.fromJson).toList();
  }

  /// Asset list that stays current: initial fetch + live price-tick folds.
  Stream<List<Asset>> watchAssets() {
    final controller = StreamController<List<Asset>>();
    final byId = <String, Asset>{};
    RealtimeChannel? channel;

    void emit() {
      final list = byId.values.toList()
        ..sort((a, b) => a.symbol.compareTo(b.symbol));
      controller.add(list);
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
              emit();
            },
          )
          .subscribe();
    };
    controller.onCancel = () {
      if (channel != null) _client.removeChannel(channel!);
    };
    return controller.stream;
  }

  /// News feed that stays current: initial fetch + live event inserts.
  Stream<List<MarketEvent>> watchEvents({int limit = 50}) {
    final controller = StreamController<List<MarketEvent>>();
    var events = <MarketEvent>[];
    RealtimeChannel? channel;

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
    };
    controller.onCancel = () {
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

final assetClassesProvider = FutureProvider<List<AssetClass>>(
  (ref) => ref.watch(marketRepositoryProvider).fetchAssetClasses(),
);

/// OHLC candles for one asset at one bucket size, timer-refreshed so the
/// forming candle stays current (same decoupling rationale as history below).
final candlesProvider = FutureProvider.autoDispose
    .family<List<Candle>, (String, int)>((ref, key) {
  final timer = Timer(const Duration(seconds: 10), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(marketRepositoryProvider).fetchCandles(key.$1, key.$2);
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
