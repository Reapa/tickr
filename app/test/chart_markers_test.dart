import 'package:flutter_test/flutter_test.dart';
import 'package:trading_game/features/market/presentation/price_chart.dart';

/// The arithmetic that places your fills on the candle chart. An off-by-one
/// here plots a trade on the wrong candle — visually plausible and therefore
/// easy to ship, which is why it is tested rather than eyeballed.
void main() {
  final first = DateTime.utc(2026, 7, 28, 12, 0, 0);
  const bucket = 300; // 5-minute candles

  int? idx(DateTime at, {int start = 0, int right = 10}) =>
      candleIndexForTime(at, first, bucket, start: start, right: right);

  group('candleIndexForTime', () {
    test('a fill on the first bucket boundary lands on candle 0', () {
      expect(idx(first), 0);
    });

    test('a fill inside a bucket lands on that bucket, not the next', () {
      expect(idx(first.add(const Duration(minutes: 4, seconds: 59))), 0);
      expect(idx(first.add(const Duration(minutes: 5))), 1);
      expect(idx(first.add(const Duration(minutes: 5, seconds: 1))), 1);
    });

    test('later fills map proportionally', () {
      expect(idx(first.add(const Duration(minutes: 30))), 6);
      expect(idx(first.add(const Duration(minutes: 47))), 9);
    });

    test('a fill before the window is not drawn', () {
      expect(idx(first.subtract(const Duration(minutes: 1))), isNull);
      expect(idx(first.add(const Duration(minutes: 10)), start: 5), isNull);
    });

    test('a fill past the right edge is not drawn', () {
      expect(idx(first.add(const Duration(minutes: 50))), isNull);
      expect(idx(first.add(const Duration(minutes: 30)), right: 6), isNull);
    });

    test('the window is half-open: right is exclusive, start inclusive', () {
      expect(idx(first.add(const Duration(minutes: 25)), start: 5, right: 6), 5);
      expect(idx(first.add(const Duration(minutes: 30)), start: 5, right: 6),
          isNull);
    });

    test('local-time input maps the same as UTC — epoch based', () {
      final utc = first.add(const Duration(minutes: 12));
      expect(idx(utc.toLocal()), idx(utc));
    });

    test('a nonsense bucket size is refused rather than dividing by zero', () {
      expect(candleIndexForTime(first, first, 0, start: 0, right: 10), isNull);
    });
  });
}
