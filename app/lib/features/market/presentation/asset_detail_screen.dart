import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/education.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/concept_chip.dart';
import '../../../core/widgets/price_flash.dart';
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
              const SizedBox(width: 12),
              Expanded(
                child: _LeverageButton(asset: asset),
              ),
            ],
          ),
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
    return FilledButton(
      style: FilledButton.styleFrom(backgroundColor: Colors.amber.shade700),
      onPressed: () => unlocked
          ? showLeverageSheet(context, asset)
          : _offerUnlock(context, ref),
      child: Text(unlocked ? '⚡ Leverage' : '⚡ 🔒'),
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

