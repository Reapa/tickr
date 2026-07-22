import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/education.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/concept_chip.dart';
import '../../../core/widgets/price_flash.dart';
import '../../leverage/data/leverage_repository.dart';
import '../../leverage/presentation/leverage_position_card.dart';
import '../../leverage/presentation/leverage_sheet.dart';
import '../../portfolio/data/portfolio_repository.dart';
import '../../profile/data/profile_repository.dart';
import '../../trading/data/trading_repository.dart';
import '../../trading/presentation/order_ticket.dart';
import '../../trading/presentation/protection_sheet.dart';
import '../data/market_repository.dart';
import '../domain/asset.dart';
import 'price_chart.dart';
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
    final levPositions = (ref.watch(leveragedPositionsProvider).value ?? const [])
        .where((p) => p.assetId == assetId && p.isOpen)
        .toList();
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
                PriceFlash(
                  price: asset.currentPrice,
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
          SizedBox(height: 280, child: PriceChart(asset: asset)),
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
              child: Column(
                children: [
                  ListTile(
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
                  _ActiveProtection(assetId: asset.id),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.shield_outlined, size: 16),
                          label: const Text('Protect (TP/SL)'),
                          onPressed: () =>
                              showProtectionSheet(context, asset, holding),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          _PendingBuyOrders(assetId: asset.id, symbol: asset.symbol),
          if (levPositions.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('⚡ Your leveraged positions',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final p in levPositions)
              LeveragePositionCard(position: p, asset: asset),
          ],
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
      bottomSheet: _TradeBar(asset: asset, hasPosition: holding != null),
    );
  }
}

/// Compact, uniform style for the three trade buttons so a longer label like
/// "Leverage" never forces the row to squash or wrap.
ButtonStyle _tradeBtnStyle({required Color bg, required Color fg}) =>
    FilledButton.styleFrom(
      backgroundColor: bg,
      foregroundColor: fg,
      padding: const EdgeInsets.symmetric(horizontal: 6),
    );

/// A single-line trade-button label that scales down instead of wrapping.
class _TradeLabel extends StatelessWidget {
  const _TradeLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, maxLines: 1, softWrap: false),
    );
  }
}

/// The buy / sell / leverage action bar. Reflects market open/closed state and
/// explains why an action is unavailable instead of leaving a dead button.
class _TradeBar extends StatelessWidget {
  const _TradeBar({required this.asset, required this.hasPosition});

  final Asset asset;
  final bool hasPosition;

  @override
  Widget build(BuildContext context) {
    final open = asset.isMarketOpenNow;
    // A single, non-clipping status line.
    final (statusLine, statusColor) = !open
        ? ('Market closed · ${asset.reopensHint}', Colors.orange)
        : hasPosition
            ? ('Market open · ${asset.marketHoursLabel}', AppTheme.up)
            : (
                "Tap Buy to open a position in ${asset.symbol}",
                Colors.grey.shade400
              );

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: AppTheme.hairline)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: open ? AppTheme.up : Colors.orange,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    statusLine,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: statusColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: _tradeBtnStyle(
                        bg: AppTheme.up, fg: Colors.black),
                    icon: const Icon(Icons.arrow_upward, size: 16),
                    onPressed: open
                        ? () => showOrderTicket(context, asset, 'buy')
                        : null,
                    label: const _TradeLabel('Buy'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    style: _tradeBtnStyle(
                        bg: AppTheme.down, fg: Colors.white),
                    icon: const Icon(Icons.arrow_downward, size: 16),
                    onPressed: open && hasPosition
                        ? () => showOrderTicket(context, asset, 'sell')
                        : null,
                    label: const _TradeLabel('Sell'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _LeverageButton(asset: asset)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the leverage ticket, or offers the broker-license unlock.
class _LeverageButton extends ConsumerWidget {
  const _LeverageButton({required this.asset});

  final Asset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked =
        ref.watch(unlockedClassesProvider).value?.contains('margin') ?? false;
    final open = asset.isMarketOpenNow;
    return FilledButton.icon(
      style: _tradeBtnStyle(bg: AppTheme.gold, fg: Colors.black),
      icon: const Icon(Icons.bolt, size: 16, color: Colors.black),
      onPressed: !open
          ? null
          : () => unlocked
              ? showLeverageSheet(context, asset)
              : _offerUnlock(context, ref),
      label: _TradeLabel(unlocked ? 'Leverage' : 'Unlock'),
    );
  }

  Future<void> _offerUnlock(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Broker license'),
        content: const Text(
            'Unlock leveraged trading for \$25,000: go long or short with '
            '5-100x your stake. High risk — a position can lose its entire '
            'margin. Ready?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not yet')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(r'Unlock for $25,000')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final receipt = await ref
          .read(tradingRepositoryProvider)
          .purchaseAssetClassUnlock('margin');
      if (receipt.status == 'unlocked') {
        ref.invalidate(unlockedClassesProvider);
        messenger.showSnackBar(const SnackBar(
            content: Text('⚡ Broker license active — trade carefully.')));
      } else {
        messenger.showSnackBar(
            SnackBar(content: Text(receipt.reason ?? 'Unlock failed')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

/// The live take-profit / stop-loss on this position. Because [openOrdersProvider]
/// now streams, a trailing stop's level visibly ratchets up here as the price
/// rises — which is the whole point of a trailing stop.
class _ActiveProtection extends ConsumerWidget {
  const _ActiveProtection({required this.assetId});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = (ref.watch(openOrdersProvider).value ?? const <OpenOrder>[])
        .where((o) => o.assetId == assetId && (o.isTakeProfit || o.isStopLoss))
        .toList();
    if (orders.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final o in orders)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(
                    o.isTakeProfit
                        ? Icons.flag
                        : o.isTrailingStop
                            ? Icons.trending_up
                            : Icons.shield,
                    size: 15,
                    color: o.isTakeProfit ? AppTheme.up : AppTheme.down,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: '${o.kindLabel} @ ${Fmt.money(o.limitPrice)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (o.isTrailingStop)
                          TextSpan(
                            text:
                                '  · trails ${o.trailLabel}, follows the price up',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Queued buy limit/stop ("future") orders for this asset, each cancellable.
class _PendingBuyOrders extends ConsumerWidget {
  const _PendingBuyOrders({required this.assetId, required this.symbol});

  final String assetId;
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = (ref.watch(openOrdersProvider).value ?? const <OpenOrder>[])
        .where((o) => o.assetId == assetId && o.isBuyEntry)
        .toList();
    if (orders.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Column(
        children: [
          const ListTile(
            dense: true,
            leading: Icon(Icons.schedule, color: AppTheme.accent),
            title: Text('Queued buy orders'),
            subtitle: Text('Fill automatically when your target price is hit.'),
          ),
          for (final o in orders)
            ListTile(
              dense: true,
              leading: Icon(
                  o.orderType == 'limit'
                      ? Icons.south_east
                      : Icons.north_east,
                  size: 18,
                  color: AppTheme.accent),
              title: Text('${o.kindLabel} · ${Fmt.quantity(o.quantity)} $symbol'),
              subtitle: Text('Triggers at ${Fmt.price(o.limitPrice)}'),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Cancel order',
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    await ref
                        .read(tradingRepositoryProvider)
                        .cancelPendingOrder(o.id);
                    ref.invalidate(openOrdersProvider);
                  } catch (error) {
                    messenger
                        .showSnackBar(SnackBar(content: Text('$error')));
                  }
                },
              ),
            ),
        ],
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

