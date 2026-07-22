import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The loaded [SharedPreferences] instance. Overridden in `main()` after it is
/// awaited, so the rest of the app can read it synchronously.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('sharedPreferencesProvider must be overridden');
});

/// Remembered chart-viewing preferences, so opening any asset restores the
/// interval and zoom the player last used instead of resetting to defaults.
class ChartPrefs {
  const ChartPrefs({required this.bucketSeconds, required this.visibleCandles});

  /// Selected candle interval in seconds; null means the line chart.
  final int? bucketSeconds;

  /// Zoom level, expressed as the number of candles kept in view.
  final double visibleCandles;

  ChartPrefs copyWith({Object? bucketSeconds = _unset, double? visibleCandles}) =>
      ChartPrefs(
        bucketSeconds: bucketSeconds == _unset
            ? this.bucketSeconds
            : bucketSeconds as int?,
        visibleCandles: visibleCandles ?? this.visibleCandles,
      );

  static const _unset = Object();
}

class ChartPrefsNotifier extends Notifier<ChartPrefs> {
  static const _kBucket = 'chart.bucketSeconds'; // -1 sentinel = line chart
  static const _kVisible = 'chart.visibleCandles';
  static const _defaultBucket = 300; // 5m
  static const _defaultVisible = 40.0;

  @override
  ChartPrefs build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final int? bucket;
    if (prefs.containsKey(_kBucket)) {
      final raw = prefs.getInt(_kBucket)!;
      bucket = raw < 0 ? null : raw;
    } else {
      bucket = _defaultBucket;
    }
    return ChartPrefs(
      bucketSeconds: bucket,
      visibleCandles: prefs.getDouble(_kVisible) ?? _defaultVisible,
    );
  }

  void setBucket(int? seconds) {
    ref.read(sharedPreferencesProvider).setInt(_kBucket, seconds ?? -1);
    state = state.copyWith(bucketSeconds: seconds);
  }

  void setVisibleCandles(double value) {
    ref.read(sharedPreferencesProvider).setDouble(_kVisible, value);
    state = state.copyWith(visibleCandles: value);
  }
}

final chartPrefsProvider =
    NotifierProvider<ChartPrefsNotifier, ChartPrefs>(ChartPrefsNotifier.new);
