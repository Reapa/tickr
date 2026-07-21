import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../data/market_repository.dart';
import '../domain/asset.dart';
import '../domain/market_event.dart';

/// Trader-style price chart: line mode plus OHLC candles at selectable
/// intervals (1m…1h), like the real thing. Candles are aggregated
/// server-side from the raw 5-second ticks.
class PriceChart extends ConsumerStatefulWidget {
  const PriceChart({super.key, required this.asset});

  final Asset asset;

  @override
  ConsumerState<PriceChart> createState() => _PriceChartState();
}

class _PriceChartState extends ConsumerState<PriceChart> {
  /// null bucket = line chart.
  static const _intervals = <(String, int?)>[
    ('Line', null),
    ('1m', 60),
    ('5m', 300),
    ('10m', 600),
    ('15m', 900),
    ('30m', 1800),
    ('1h', 3600),
  ];

  int? _bucketSeconds = 300; // default: 5m candles

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final (label, bucket) in _intervals)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    selected: _bucketSeconds == bucket,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) =>
                        setState(() => _bucketSeconds = bucket),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _bucketSeconds == null
              ? _LineMode(asset: widget.asset)
              : _CandleMode(asset: widget.asset, bucketSeconds: _bucketSeconds!),
        ),
      ],
    );
  }
}

class _CandleMode extends ConsumerWidget {
  const _CandleMode({required this.asset, required this.bucketSeconds});

  final Asset asset;
  final int bucketSeconds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final candles =
        ref.watch(candlesProvider((asset.id, bucketSeconds))).value;
    if (candles == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (candles.length < 2) {
      return const Center(
          child: Text('Not enough history for this interval yet…'));
    }

    final spots = <CandlestickSpot>[
      for (final (index, c) in candles.indexed)
        CandlestickSpot(
          x: index.toDouble(),
          open: c.open,
          high: c.high,
          low: c.low,
          close: c.close,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bodyWidth =
              (constraints.maxWidth / candles.length * 0.6).clamp(2.0, 14.0);
          return CandlestickChart(
            CandlestickChartData(
              candlestickSpots: spots,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (value) => FlLine(
                  color: Colors.white.withValues(alpha: 0.05),
                  strokeWidth: 1,
                ),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                leftTitles: const AxisTitles(),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: (candles.length / 4).clamp(1, 999).toDouble(),
                    getTitlesWidget: (value, meta) {
                      final index = value.toInt();
                      if (index < 0 || index >= candles.length) {
                        return const SizedBox.shrink();
                      }
                      final t = candles[index].bucket;
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
                rightTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 56,
                    getTitlesWidget: (value, meta) => Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        Fmt.moneyCompact(value),
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ),
              ),
              borderData: FlBorderData(show: false),
              candlestickPainter: DefaultCandlestickPainter(
                candlestickStyleProvider: (spot, index) => CandlestickStyle(
                  lineColor: spot.isUp ? AppTheme.up : AppTheme.down,
                  lineWidth: 1.2,
                  bodyStrokeColor: Colors.transparent,
                  bodyStrokeWidth: 0,
                  bodyFillColor: spot.isUp ? AppTheme.up : AppTheme.down,
                  bodyWidth: bodyWidth,
                  bodyRadius: 1,
                ),
              ),
            ),
            duration: Duration.zero,
          );
        },
      ),
    );
  }
}

class _LineMode extends ConsumerWidget {
  const _LineMode({required this.asset});

  final Asset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fetched = ref.watch(priceHistoryProvider(asset.id)).value;
    if (fetched == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // Live price appended so the right edge never lags the header.
    final points = [
      ...fetched,
      PricePoint(price: asset.currentPrice, time: DateTime.now()),
    ];
    if (points.length < 2) {
      return const Center(child: Text('Chart appears after a few ticks…'));
    }
    final rising = points.last.price >= points.first.price;
    final color = rising ? AppTheme.up : AppTheme.down;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LineChart(
        LineChartData(
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (touched) => [
                for (final spot in touched)
                  LineTooltipItem(
                    Fmt.money(spot.y),
                    const TextStyle(fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (final p in points)
                  FlSpot(p.time.millisecondsSinceEpoch.toDouble(), p.price),
              ],
              isCurved: false,
              color: color,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: color.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
        duration: Duration.zero,
      ),
    );
  }
}
