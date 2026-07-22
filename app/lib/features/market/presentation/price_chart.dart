import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cosmetics.dart';
import '../../../core/format.dart';
import '../../../core/prefs.dart';
import '../../../core/theme.dart';
import '../../profile/data/profile_repository.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../trading/data/trading_repository.dart';
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

  late int? _bucketSeconds = ref.read(chartPrefsProvider).bucketSeconds;

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
          color: order.isTakeProfit
              ? AppTheme.up
              : order.isStopLoss
                  ? AppTheme.down
                  : AppTheme.accent, // buy limit/stop (a queued entry)
          label: order.isTakeProfit
              ? 'TP'
              : order.isStopLoss
                  ? 'SL'
                  : order.orderType == 'limit'
                      ? 'Buy ▼'
                      : 'Buy ▲',
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
                    onSelected: (_) {
                      setState(() => _bucketSeconds = bucket);
                      ref.read(chartPrefsProvider.notifier).setBucket(bucket);
                    },
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

class _CandleMode extends ConsumerStatefulWidget {
  const _CandleMode({
    required this.asset,
    required this.bucketSeconds,
    required this.markers,
  });

  final Asset asset;
  final int bucketSeconds;
  final List<ChartMarker> markers;

  @override
  ConsumerState<_CandleMode> createState() => _CandleModeState();
}

class _CandleModeState extends ConsumerState<_CandleMode> {
  // Height reserved for the time axis; also lets us map price <-> Y for the
  // draggable protection handles so they line up with the chart's plot area.
  static const double _kBottomAxis = 22;

  // Windowing state: how many candles are visible (zoom) and how far the right
  // edge sits from the newest candle (pan; 0 = following the live edge).
  // The zoom level is seeded from and written back to the player's saved prefs.
  late double _visible = ref.read(chartPrefsProvider).visibleCandles;
  double _fromEnd = 0;
  late double _scaleStartVisible = _visible;

  /// Persist the current zoom so reopening any chart restores it.
  void _saveZoom() =>
      ref.read(chartPrefsProvider.notifier).setVisibleCandles(_visible);

  // The candle whose OHLC tooltip is showing (null = none). Driven manually so
  // it clears the moment the finger lifts — the built-in tooltip would stick,
  // because the pan/zoom GestureDetector swallows the pointer-up event.
  int? _touchedIndex;

  void _clearTouch() {
    if (_touchedIndex != null) setState(() => _touchedIndex = null);
  }

  // Which protection line ('TP'/'SL') is being dragged, and its live price.
  String? _dragLabel;
  double? _dragPrice;

  /// Commit a dragged take-profit / stop-loss to the server.
  Future<void> _persistProtection(String label) async {
    final price = _dragPrice;
    if (price == null) {
      setState(() => _dragLabel = null);
      return;
    }
    try {
      await ref.read(tradingRepositoryProvider).setPositionProtection(
            assetId: widget.asset.id,
            takeProfit: label == 'TP' ? price : null,
            stopLoss: label == 'SL' ? price : null,
          );
      ref.invalidate(openOrdersProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update: $error')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _dragLabel = null;
          _dragPrice = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final candles = ref
        .watch(candlesProvider((widget.asset.id, widget.bucketSeconds)))
        .value;
    if (candles == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (candles.length < 2) {
      return const Center(
          child: Text('Not enough history for this interval yet…'));
    }

    // Equipped chart-theme cosmetic recolours the candles.
    final chart = equippedChartTheme(ref.watch(myProfileProvider).value?.equipped);

    final total = candles.length;
    // Guard: with fewer than 8 candles the lower bound would exceed total.
    final minVisible = total < 8 ? total : 8;
    final visible = _visible.clamp(minVisible, total).round();
    final fromEnd = _fromEnd.clamp(0, total - visible).round();
    final right = total - fromEnd; // exclusive
    final start = right - visible;
    final window = candles.sublist(start, right);
    final includesLive = right == total;
    final live = widget.asset.currentPrice;

    final spots = <CandlestickSpot>[
      for (final (i, c) in window.indexed)
        if (includesLive && i == window.length - 1)
          CandlestickSpot(
            x: i.toDouble(),
            open: c.open,
            high: c.high < live ? live : c.high,
            low: c.low > live ? live : c.low,
            close: live,
          )
        else
          CandlestickSpot(
              x: i.toDouble(),
              open: c.open,
              high: c.high,
              low: c.low,
              close: c.close),
    ];
    final (minY, maxY) = _yRange(
      [
        ...window.expand((c) => [c.low, c.high]),
        if (includesLive) live,
      ],
      widget.markers,
    );
    final bandHalf = (maxY - minY) * 0.0025;

    // While a TP/SL handle is being dragged, render that line at the dragged
    // price. The Y range stays fixed to widget.markers so the drag maps 1:1.
    final displayMarkers = _dragLabel == null
        ? widget.markers
        : [
            for (final m in widget.markers)
              (m.label == _dragLabel && _dragPrice != null)
                  ? (price: _dragPrice!, color: m.color, label: m.label)
                  : m,
          ];

    void zoom(double factor) {
      setState(() {
        _visible = (_visible * factor)
            .clamp(minVisible.toDouble(), total.toDouble());
      });
      _saveZoom();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final chartWidth = constraints.maxWidth - 56; // minus price axis
          final candlePx = (chartWidth / window.length).clamp(1.0, 1e9);
          final bodyWidth = (candlePx * 0.62).clamp(2.0, 16.0);
          // Hold the newest candle a fixed pixel gap clear of the price axis so
          // the price labels and the draggable SL/TP handle never sit on top of
          // it. Expressed in candle units (gap ÷ candle width) so it stays the
          // same width in pixels at every zoom level.
          const rightGapPx = 44.0;
          final maxX = (window.length - 1) + rightGapPx / candlePx;
          final tip = (_touchedIndex != null && _touchedIndex! < spots.length)
              ? [_touchedIndex!]
              : const <int>[];
          // Map a price to its Y pixel within the plot area (above the axis).
          final plotHeight =
              (constraints.maxHeight - _kBottomAxis).clamp(1.0, double.infinity);
          final span = (maxY - minY).abs() < 1e-9 ? 1.0 : maxY - minY;
          double yForPrice(double price) => (maxY - price) / span * plotHeight;
          return Stack(
            children: [
              // Listener catches the raw pointer-up even when the gesture is
              // claimed by the pan/zoom recognizer, guaranteeing the tooltip
              // clears when the finger leaves the screen.
              Listener(
                onPointerUp: (_) => _clearTouch(),
                onPointerCancel: (_) => _clearTouch(),
                child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (_) => _scaleStartVisible = _visible,
                onScaleEnd: (_) => _saveZoom(),
                onScaleUpdate: (details) {
                  setState(() {
                    // Pinch → zoom (fewer candles as you spread fingers).
                    if (details.scale != 1.0) {
                      _visible = (_scaleStartVisible / details.scale)
                          .clamp(minVisible.toDouble(), total.toDouble());
                    }
                    // Drag → pan back/forward through history.
                    final candleW = chartWidth / visible;
                    _fromEnd = (_fromEnd + details.focalPointDelta.dx / candleW)
                        .clamp(0, (total - visible).toDouble());
                  });
                },
                child: CandlestickChart(
                  CandlestickChartData(
                    candlestickSpots: spots,
                    minX: 0,
                    maxX: maxX,
                    minY: minY,
                    maxY: maxY,
                    showingTooltipIndicators: tip,
                    candlestickTouchData: CandlestickTouchData(
                      // Override the default OHLC tooltip, which renders values
                      // as whole numbers (.toInt()) — useless for slow movers.
                      touchTooltipData: CandlestickTouchTooltipData(
                        getTooltipItems: (painter, spot, index) {
                          final color = spot.isUp ? chart.up : chart.down;
                          final label = TextStyle(
                              color: Colors.grey.shade400, fontSize: 11);
                          final val = TextStyle(
                              color: color,
                              fontSize: 11,
                              fontWeight: FontWeight.w700);
                          TextSpan row(String k, double v, {bool last = false}) =>
                              TextSpan(children: [
                                TextSpan(text: k, style: label),
                                TextSpan(
                                    text:
                                        '${widget.asset.isForex ? Fmt.quote(v) : Fmt.price(v)}${last ? '' : '\n'}',
                                    style: val),
                              ]);
                          return CandlestickTooltipItem('',
                              textAlign: TextAlign.left,
                              children: [
                                row('O ', spot.open),
                                row('H ', spot.high),
                                row('L ', spot.low),
                                row('C ', spot.close, last: true),
                              ]);
                        },
                      ),
                      // We drive the tooltip ourselves via showingTooltipIndicators
                      // so it can be dismissed on pointer-up.
                      handleBuiltInTouches: false,
                      touchCallback: (event, response) {
                        final idx = response?.touchedSpot?.spotIndex;
                        final ended = event is FlTapUpEvent ||
                            event is FlTapCancelEvent ||
                            event is FlPanEndEvent ||
                            event is FlPanCancelEvent ||
                            event is FlPointerExitEvent ||
                            event is FlLongPressEnd;
                        final next = (ended || idx == null) ? null : idx;
                        if (next != _touchedIndex) {
                          setState(() => _touchedIndex = next);
                        }
                      },
                    ),
                    rangeAnnotations: RangeAnnotations(
                      horizontalRangeAnnotations: [
                        for (final marker in displayMarkers)
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
                          strokeWidth: 1),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      leftTitles: const AxisTitles(),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: _kBottomAxis,
                          interval:
                              (window.length / 4).clamp(1, 999).toDouble(),
                          getTitlesWidget: (value, meta) {
                            final index = value.toInt();
                            if (index < 0 || index >= window.length) {
                              return const SizedBox.shrink();
                            }
                            final t = window[index].bucket;
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
                                widget.asset.isForex
                                    ? Fmt.quote(value)
                                    : Fmt.priceAxis(value),
                                style: const TextStyle(fontSize: 10)),
                          ),
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    candlestickPainter: DefaultCandlestickPainter(
                      candlestickStyleProvider: (spot, index) =>
                          CandlestickStyle(
                        lineColor: spot.isUp ? chart.up : chart.down,
                        lineWidth: 1.2,
                        bodyStrokeColor: Colors.transparent,
                        bodyStrokeWidth: 0,
                        bodyFillColor: spot.isUp ? chart.up : chart.down,
                        bodyWidth: bodyWidth,
                        bodyRadius: 1,
                      ),
                    ),
                  ),
                  duration: Duration.zero,
                ),
                ),
              ),
              // Zoom / pan controls.
              Positioned(
                top: 0,
                left: 0,
                child: Row(
                  children: [
                    _ChartBtn(
                        icon: Icons.remove,
                        onTap: () => zoom(1.4)),
                    _ChartBtn(icon: Icons.add, onTap: () => zoom(0.7)),
                    if (fromEnd > 0 || visible != 40)
                      _ChartBtn(
                        icon: Icons.skip_next,
                        tooltip: 'Live',
                        onTap: () {
                          setState(() {
                            _fromEnd = 0;
                            _visible = 40;
                          });
                          _saveZoom();
                        },
                      ),
                  ],
                ),
              ),
              // Draggable TP / SL handles, pinned to the price axis. Drag to
              // adjust; releasing commits the new level to the server.
              for (final m in displayMarkers)
                if (m.label == 'TP' || m.label == 'SL')
                  Positioned(
                    right: 0,
                    top: (yForPrice(m.price) - 12)
                        .clamp(0.0, plotHeight - 24),
                    child: _ProtectionHandle(
                      label: m.label,
                      price: m.price,
                      color: m.color,
                      onDragStart: () => setState(() {
                        _dragLabel = m.label;
                        _dragPrice = m.price;
                      }),
                      onDragDelta: (dy) => setState(() {
                        var p = (_dragPrice ?? m.price) - dy / plotHeight * span;
                        p = p.clamp(minY, maxY);
                        // Keep TP above and SL below the live price so the
                        // server won't reject the level.
                        if (m.label == 'TP' && p < live * 1.001) {
                          p = live * 1.001;
                        } else if (m.label == 'SL' && p > live * 0.999) {
                          p = live * 0.999;
                        }
                        _dragPrice = p;
                      }),
                      onDragEnd: () => _persistProtection(m.label),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// A grab handle for a take-profit / stop-loss line, sitting in the price
/// gutter. Vertical drags move the level; release commits it.
class _ProtectionHandle extends StatelessWidget {
  const _ProtectionHandle({
    required this.label,
    required this.price,
    required this.color,
    required this.onDragStart,
    required this.onDragDelta,
    required this.onDragEnd,
  });

  final String label;
  final double price;
  final Color color;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragDelta;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => onDragStart(),
      onVerticalDragUpdate: (d) => onDragDelta(d.delta.dy),
      onVerticalDragEnd: (_) => onDragEnd(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.drag_indicator, size: 12, color: Colors.black),
            Text(
              '$label ${Fmt.price(price)}',
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Colors.black),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartBtn extends StatelessWidget {
  const _ChartBtn({required this.icon, required this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: AppTheme.hairline),
        ),
        child: Icon(icon, size: 16),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
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
    final chart = equippedChartTheme(ref.watch(myProfileProvider).value?.equipped);
    final rising = points.last.price >= points.first.price;
    final color = rising ? chart.up : chart.down;
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
                    asset.isForex ? Fmt.quote(spot.y) : Fmt.price(spot.y),
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
