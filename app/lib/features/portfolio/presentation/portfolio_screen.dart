import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/education.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/concept_chip.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../../missions/data/missions_repository.dart';
import '../../profile/data/profile_repository.dart';
import '../../trading/data/trading_repository.dart';
import '../../trading/presentation/protection_sheet.dart';
import '../data/portfolio_repository.dart';
import '../domain/holding.dart';
import '../domain/portfolio_math.dart';

class PortfolioScreen extends ConsumerWidget {
  const PortfolioScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final holdings = ref.watch(holdingsProvider).value ?? const <Holding>[];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final prices = {for (final a in assets) a.id: a.currentPrice};
    final assetById = {for (final a in assets) a.id: a};

    final marketValue = PortfolioMath.marketValue(holdings, prices);
    final cash = profile?.cashBalance ?? 0;
    final sectorWeights = PortfolioMath.sectorWeights(
      holdings,
      prices,
      {for (final a in assets) a.id: a.sector},
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Portfolio'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: ConceptChip(Concepts.netWorth)),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(netWorthHistoryProvider);
          ref.invalidate(recentOrdersProvider);
          ref.invalidate(openOrdersProvider);
        },
        child: ListView(
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Net worth',
                        style: Theme.of(context).textTheme.bodySmall),
                    Text(
                      Fmt.money(profile?.netWorth ?? cash + marketValue),
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _SummaryStat(label: 'Cash', value: Fmt.money(cash)),
                        const SizedBox(width: 24),
                        _SummaryStat(
                            label: 'Invested', value: Fmt.money(marketValue)),
                        const SizedBox(width: 24),
                        const _TodayStat(),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 180, child: _NetWorthChart()),
            if (sectorWeights.isNotEmpty)
              _DiversificationCard(weights: sectorWeights),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Positions',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (holdings.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      'No positions yet. Head to the Market tab and put your '
                      'starting cash to work.'),
                ),
              )
            else
              for (final holding in holdings)
                _HoldingTile(
                  holding: holding,
                  asset: assetById[holding.assetId],
                ),
            const _RecentOrders(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value,
            style: TextStyle(fontWeight: FontWeight.w600, color: color)),
      ],
    );
  }
}

/// Net-worth change since the start of the loaded history window (24h).
class _TodayStat extends ConsumerWidget {
  const _TodayStat();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(netWorthHistoryProvider).value;
    final current = ref.watch(myProfileProvider).value?.netWorth;
    if (history == null || history.isEmpty || current == null) {
      return const _SummaryStat(label: 'Today', value: '—');
    }
    final delta = current - history.first.netWorth;
    return _SummaryStat(
      label: 'Today',
      value: '${delta >= 0 ? '+' : ''}${Fmt.money(delta)}',
      color: AppTheme.changeColor(delta),
    );
  }
}

class _NetWorthChart extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(netWorthHistoryProvider).value;
    if (history == null || history.length < 2) {
      return const Center(
          child: Text('Your portfolio chart appears after a few ticks…'));
    }
    final rising = history.last.netWorth >= history.first.netWorth;
    final color = rising ? AppTheme.up : AppTheme.down;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: LineChart(
        LineChartData(
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (touched) => [
                for (final spot in touched)
                  LineTooltipItem(Fmt.money(spot.y),
                      const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (final point in history)
                  FlSpot(point.time.millisecondsSinceEpoch.toDouble(),
                      point.netWorth),
              ],
              isCurved: false,
              color: color,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData:
                  BarAreaData(show: true, color: color.withValues(alpha: 0.12)),
            ),
          ],
        ),
        duration: Duration.zero,
      ),
    );
  }
}

class _DiversificationCard extends StatelessWidget {
  const _DiversificationCard({required this.weights});

  final Map<String, double> weights;

  @override
  Widget build(BuildContext context) {
    final entries = weights.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Diversification',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 8),
                const ConceptChip(Concepts.diversification),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Row(
                children: [
                  for (final (index, entry) in entries.indexed)
                    Expanded(
                      flex: (entry.value * 1000).round().clamp(1, 1000),
                      child: Container(
                        height: 8,
                        color: Colors.primaries[
                            (index * 4) % Colors.primaries.length],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              children: [
                for (final entry in entries)
                  Text(
                    '${entry.key.toUpperCase()} ${(entry.value * 100).toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            if (entries.length < 3)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Tip: holding 3+ sectors cushions bad news (and completes '
                  'a mission).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HoldingTile extends ConsumerWidget {
  const _HoldingTile({required this.holding, required this.asset});

  final Holding holding;
  final Asset? asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = asset;
    if (a == null) return const SizedBox.shrink();
    final pnl = PortfolioMath.unrealizedPnl(holding, a.currentPrice);
    final ret = PortfolioMath.unrealizedReturn(holding, a.currentPrice);
    final protection = (ref.watch(openOrdersProvider).value ?? const [])
        .where((o) => o.assetId == a.id)
        .toList();
    return Card(
      child: Column(
        children: [
          ListTile(
            onTap: () => context.go('/market/asset/${a.id}'),
            title: Text('${a.symbol} · ${Fmt.quantity(holding.quantity)} units'),
            subtitle: Text(
                'Avg ${Fmt.money(holding.avgCost)} · now ${Fmt.money(a.currentPrice)}'),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Fmt.money(holding.quantity * a.currentPrice),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  '${Fmt.money(pnl)} (${Fmt.pct(ret)})',
                  style:
                      TextStyle(color: AppTheme.changeColor(pnl), fontSize: 12),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                if (protection.isNotEmpty)
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final order in protection)
                          Text(
                            '${order.isTakeProfit ? '🎯 TP' : '🛡 SL'} '
                            '${Fmt.money(order.limitPrice)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: order.isTakeProfit
                                  ? AppTheme.up
                                  : AppTheme.down,
                            ),
                          ),
                      ],
                    ),
                  )
                else
                  const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.shield_outlined, size: 16),
                  label: Text(protection.isEmpty ? 'Protect' : 'Edit'),
                  onPressed: () => showProtectionSheet(context, a, holding),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.logout, size: 16),
                  style: TextButton.styleFrom(foregroundColor: AppTheme.down),
                  label: const Text('Close'),
                  onPressed: () => _closePosition(context, ref, a),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _closePosition(
      BuildContext context, WidgetRef ref, Asset a) async {
    final estProceeds = holding.quantity * a.bidPrice;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Close ${a.symbol} position?'),
        content: Text(
            'Sell all ${Fmt.quantity(holding.quantity)} units at market '
            '(~${Fmt.money(estProceeds)}).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.down),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close position'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final receipt = await ref.read(tradingRepositoryProvider).placeMarketOrder(
          assetId: a.id, side: 'sell', quantity: holding.quantity);
      ref.invalidate(holdingsProvider);
      ref.invalidate(openOrdersProvider);
      ref.invalidate(recentOrdersProvider);
      ref.invalidate(ledgerProvider);
      ref.invalidate(missionsProvider);
      messenger.showSnackBar(SnackBar(
        content: Text(receipt.isFilled
            ? 'Closed ${a.symbol}: +${Fmt.money(receipt.notional ?? 0)}'
            : 'Close failed: ${receipt.reason}'),
      ));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class _RecentOrders extends ConsumerWidget {
  const _RecentOrders();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(recentOrdersProvider).value ?? const <OrderRow>[];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final symbolById = {for (final a in assets) a.id: a.symbol};
    if (orders.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Recent orders',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        for (final order in orders.take(10))
          ListTile(
            dense: true,
            leading: Icon(
              order.side == 'buy' ? Icons.add : Icons.remove,
              color: order.status == 'filled'
                  ? (order.side == 'buy' ? AppTheme.up : AppTheme.down)
                  : Colors.grey,
            ),
            title: Text(
              '${order.side.toUpperCase()} ${Fmt.quantity(order.quantity)} '
              '${symbolById[order.assetId] ?? '?'} — ${order.status}'
              '${order.rejectReason != null ? ' (${order.rejectReason})' : ''}',
            ),
            subtitle: Text(Fmt.timeAgo(order.createdAt)),
          ),
      ],
    );
  }
}
