import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/education.dart';
import '../../../core/brand.dart';
import '../../../core/feedback.dart';
import '../../../core/format.dart';
import '../../../core/sector_colors.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/concept_chip.dart';
import '../../../core/widgets/price_flash.dart';
import '../../../core/widgets/tutorial_tip.dart';
import '../../leverage/data/leverage_repository.dart';
import '../../leverage/presentation/leverage_position_card.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../../missions/data/missions_repository.dart';
import '../../profile/data/profile_repository.dart';
import '../../trading/data/trading_repository.dart';
import '../../trading/presentation/protection_sheet.dart';
import '../data/portfolio_repository.dart';
import 'allocation_donut.dart';
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
      appBar: tickrAppBar(
        title: 'Portfolio',
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
            const TutorialTip(
              id: 'portfolio',
              text: 'Your net worth is cash plus everything you hold, marked to '
                  'live prices. The chart tracks it over time; positions and '
                  'queued orders sit below.',
            ),
            Card(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppTheme.accent.withValues(alpha: 0.16),
                      AppTheme.surface,
                      AppTheme.up.withValues(alpha: 0.10),
                    ],
                  ),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('NET WORTH',
                        style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade400)),
                    const SizedBox(height: 2),
                    AnimatedMoney(
                      value: profile?.netWorth ?? cash + marketValue,
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
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
            const _NetWorthChart(),
            const AllocationDonut(),
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
            const _LeveragedSection(),
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

class _NetWorthChart extends ConsumerStatefulWidget {
  const _NetWorthChart();

  @override
  ConsumerState<_NetWorthChart> createState() => _NetWorthChartState();
}

class _NetWorthChartState extends ConsumerState<_NetWorthChart> {
  static const _ranges = <(String, Duration)>[
    ('1H', Duration(hours: 1)),
    ('1D', Duration(hours: 24)),
    ('1W', Duration(days: 7)),
  ];
  int _range = 1; // default 1D

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(netWorthHistoryProvider).value;
    final cutoff = DateTime.now().subtract(_ranges[_range].$2);
    var history = (all ?? const [])
        .where((p) => p.time.isAfter(cutoff))
        .toList();
    // Fall back to whatever we have if the window is too sparse.
    if (history.length < 2 && all != null && all.length >= 2) {
      history = all;
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 12, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              for (final (i, r) in _ranges.indexed)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: GestureDetector(
                    onTap: () => setState(() => _range = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _range == i
                            ? AppTheme.brand.withValues(alpha: 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(r.$1,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _range == i
                                  ? AppTheme.brand
                                  : Colors.grey.shade500)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 160,
          child: history.length < 2
              ? const Center(
                  child: Text('Your chart appears after a few ticks…'))
              : _chart(history),
        ),
      ],
    );
  }

  Widget _chart(List<NetWorthPoint> history) {
    final rising = history.last.netWorth >= history.first.netWorth;
    final color = rising ? AppTheme.up : AppTheme.down;
    final lastX = history.last.time.millisecondsSinceEpoch.toDouble();
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
                      const TextStyle(fontWeight: FontWeight.w700)),
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
              barWidth: 2.5,
              // Emphasize only the live endpoint.
              dotData: FlDotData(
                show: true,
                checkToShowDot: (spot, _) => spot.x == lastX,
                getDotPainter: (spot, pct, bar, i) => FlDotCirclePainter(
                    radius: 4,
                    color: color,
                    strokeColor: AppTheme.background,
                    strokeWidth: 2),
              ),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    color.withValues(alpha: 0.22),
                    color.withValues(alpha: 0.0)
                  ],
                ),
              ),
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
                  for (final entry in entries)
                    Expanded(
                      flex: (entry.value * 1000).round().clamp(1, 1000),
                      child: Container(
                        height: 8,
                        color: SectorColors.of(entry.key),
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
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: SectorColors.of(entry.key)),
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
      final pnl = receipt.realizedPnl;
      if (receipt.isFilled && pnl != null && context.mounted) {
        Juice.close(context, ref, pnl: pnl, symbol: a.symbol);
      }
      messenger.showSnackBar(SnackBar(
        content: Text(receipt.isFilled
            ? (pnl != null
                ? 'Closed ${a.symbol} · ${pnl >= 0 ? 'profit' : 'loss'} '
                    '${pnl >= 0 ? '+' : ''}${Fmt.money(pnl)}'
                : 'Closed ${a.symbol}')
            : 'Close failed: ${receipt.reason}'),
        backgroundColor: receipt.isFilled && pnl != null
            ? AppTheme.changeColor(pnl).withValues(alpha: 0.9)
            : null,
      ));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class _LeveragedSection extends ConsumerWidget {
  const _LeveragedSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positions =
        ref.watch(leveragedPositionsProvider).value ?? const [];
    if (positions.isEmpty) return const SizedBox.shrink();
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final assetById = {for (final a in assets) a.id: a};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('⚡ Leveraged positions',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        for (final position in positions)
          LeveragePositionCard(
            position: position,
            asset: assetById[position.assetId],
          ),
      ],
    );
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
            trailing: order.isRealizedClose
                ? _RealizedPnl(order: order)
                : null,
          ),
      ],
    );
  }
}

/// The realized profit/loss on a closed sell — the number a player misses when
/// a stop-loss or take-profit fires while they're away.
class _RealizedPnl extends StatelessWidget {
  const _RealizedPnl({required this.order});

  final OrderRow order;

  @override
  Widget build(BuildContext context) {
    final pnl = order.realizedPnl ?? 0;
    final ret = order.realizedReturn;
    final color = AppTheme.changeColor(pnl);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '${pnl >= 0 ? '+' : ''}${Fmt.money(pnl)}',
          style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        Text(
          ret == null ? 'realized' : '${pnl >= 0 ? '+' : ''}${Fmt.pct(ret)}',
          style: TextStyle(fontSize: 10.5, color: color.withValues(alpha: 0.8)),
        ),
      ],
    );
  }
}
