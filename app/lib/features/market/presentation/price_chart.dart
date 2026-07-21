import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../data/market_repository.dart';
import '../domain/asset.dart';
import '../domain/market_event.dart';

/// A price level drawn across the chart: your buy-in, TP, or SL.
typedef ChartMarker = ({double price, Color color, String label});

/// Trader-style price chart: line mode plus OHLC candles at selectable
/// intervals (1m…1h). Overlays your position's average cost and any active
/// take-profit / stop-loss levels in both modes.
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
    final asset = widget.asset;
    final holding = ref
        .watch(holdingsProvider)
        .value
        ?.where((h) => h.assetId == asset.id)
        .firstOrNull;
    final protection = (ref.watch(openOrdersProvider).value ?? const [])
        .where((o) => o.assetId == asset.id);

    final markers = <ChartMarker>[
      if (holding != null)
        (price: holding.avgCost, color: Colors.amber, label: 'Avg'),
      for (final order in protection)
        (
          price: order.limitPrice,
          color: order.isTakeProfit ? AppTheme.up : AppTheme.down,
          label: order.isTakeProfit ? 'TP' : 'SL',
        ),
    ];

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
                    onSelected: (_) => setState(() => _bucketSeconds = bucket),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _bucketSeconds == null
              ? _LineMode(asset: asset, markers: markers)
              : _CandleMode(
                  asset: asset,
                  bucketSeconds: _bucketSeconds!,
                  markers: markers,
                ),
        ),
        if (markers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
            child: Wrap(
              spacing: 14,
              children: [
                for (final marker in markers)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 2,
                        color: marker.color,
                        margin: const EdgeInsets.only(right: 4),
                      ),
                      Text(
                        '${marker.label} ${Fmt.money(marker.price)}',
                        style:
                            TextStyle(fontSize: 11, color: marker.color),
                      ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Y-range covering both the data and every marker, with breathing room.
(double, double) _yRange(Iterable<double> dataValues, List<ChartMarker> markers) {
  final values = [...dataValues, for (final m in markers) m.price];
  var lo = values.reduce((a, b) => a < b ? a : b);
  var hi = values.reduce((a, b) => a > b ? a : b);
  final pad = (hi - lo) * 0.08 + hi * 0.001;
  lo -= pad;
  hi += pad;
  return (lo <= 0 ? 0.01 : lo, hi);
}

class _CandleMode extends ConsumerWidget {
  const _CandleMode({
    required this.asset,
    required this.bucketSeconds,
    required this.markers,
  });

  final Asset asset;
  final int bucketSeconds;
  final List<ChartMarker> markers;

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
    final (minY, maxY) = _yRange(
      candles.expand((c) => [c.low, c.high]),
      markers,
    );
    // Markers as thin horizontal bands (candlestick charts support range
    // annotations, not extra lines); the legend below carries the values.
    final bandHalf = (maxY - minY) * 0.0025;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bodyWidth =
              (constraints.maxWidth / candles.length * 0.6).clamp(2.0, 14.0);
          return CandlestickChart(
            CandlestickChartData(
              candlestickSpots: spots,
              minY: minY,
              maxY: maxY,
              rangeAnnotations: RangeAnnotations(
                horizontalRangeAnnotations: [
                  for (final marker in markers)
                    HorizontalRangeAnnotation(
                      y1: marker.price - bandHalf,
                      y2: marker.price + bandHalf,
                      color: marker.color.withValues(alpha: 0.55),
                    ),
                ],
              ),
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
  const _LineMode({required this.asset, required this.markers});

  final Asset asset;
  final List<ChartMarker> markers;

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
    final (minY, maxY) = _yRange(points.map((p) => p.price), markers);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              for (final marker in markers)
                HorizontalLine(
                  y: marker.price,
                  color: marker.color.withValues(alpha: 0.85),
                  strokeWidth: 1,
                  dashArray: [6, 4],
                  label: HorizontalLineLabel(
                    show: true,
                    alignment: Alignment.topLeft,
                    padding: const EdgeInsets.only(left: 2, bottom: 2),
                    style: TextStyle(fontSize: 10, color: marker.color),
                    labelResolver: (line) =>
                        '${marker.label} ${Fmt.money(marker.price)}',
                  ),
                ),
            ],
          ),
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
