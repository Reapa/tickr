import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/education.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/concept_chip.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../trading/presentation/order_ticket.dart';
import '../data/market_repository.dart';
import '../domain/asset.dart';
import '../domain/market_event.dart';
import 'widgets.dart';

class AssetDetailScreen extends ConsumerWidget {
  const AssetDetailScreen({super.key, required this.assetId});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final asset = assets.where((a) => a.id == assetId).firstOrNull;

    if (asset == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final holding = ref
        .watch(holdingsProvider)
        .value
        ?.where((h) => h.assetId == assetId)
        .firstOrNull;
    final events = ref.watch(marketEventsProvider).value ?? const [];
    final assetEvents = events
        .where((e) =>
            e.assetId == asset.id ||
            (e.scope == 'sector' && e.sector == asset.sector) ||
            e.scope == 'market')
        .take(10)
        .toList();

    return Scaffold(
      appBar: AppBar(title: Text('${asset.symbol} · ${asset.name}')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Fmt.money(asset.currentPrice),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ChangeBadge(
                      assetId: asset.id, currentPrice: asset.currentPrice),
                ),
              ],
            ),
          ),
          SizedBox(height: 220, child: _PriceChart(asset: asset)),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Stat(label: 'Sector', value: asset.sector.toUpperCase()),
                _Stat(label: 'Ask', value: Fmt.money(asset.askPrice)),
                _Stat(label: 'Bid', value: Fmt.money(asset.bidPrice)),
                _Stat(
                    label: 'Spread',
                    value: '${(asset.spread * 100).toStringAsFixed(2)}%'),
                const ConceptChip(Concepts.spread),
                const ConceptChip(Concepts.meanReversion),
              ],
            ),
          ),
          if (holding != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.work_outline),
                title: Text(
                    'You hold ${Fmt.quantity(holding.quantity)} @ '
                    '${Fmt.money(holding.avgCost)} avg'),
                subtitle: Text(
                  'Unrealized: ${Fmt.money(holding.quantity * (asset.currentPrice - holding.avgCost))}',
                  style: TextStyle(
                    color: AppTheme.changeColor(
                        asset.currentPrice - holding.avgCost),
                  ),
                ),
                trailing: const ConceptChip(Concepts.avgCost),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(asset.description,
                style: Theme.of(context).textTheme.bodyMedium),
          ),
          if (assetEvents.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Related news',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final event in assetEvents)
              EventTile(event: event, symbol: asset.symbol),
          ],
        ],
      ),
      bottomSheet: Container(
        color: AppTheme.background,
        padding: const EdgeInsets.all(12),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.up),
                  onPressed: () => showOrderTicket(context, asset, 'buy'),
                  child: const Text('Buy'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.down),
                  onPressed: holding == null
                      ? null
                      : () => showOrderTicket(context, asset, 'sell'),
                  child: const Text('Sell'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _PriceChart extends ConsumerWidget {
  const _PriceChart({required this.asset});

  final Asset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(priceHistoryProvider(asset.id));
    final fetched = history.value;
    if (fetched == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // History refreshes every 15s; the live price (updated every tick via
    // Realtime) is appended so the chart's right edge never lags the header.
    final points = [
      ...fetched,
      PricePoint(price: asset.currentPrice, time: DateTime.now()),
    ];
    if (points.length < 2) {
      return const Center(child: Text('Chart appears after a few ticks…'));
    }
    final spots = [
      for (final p in points)
        FlSpot(p.time.millisecondsSinceEpoch.toDouble(), p.price),
    ];
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
              spots: spots,
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
