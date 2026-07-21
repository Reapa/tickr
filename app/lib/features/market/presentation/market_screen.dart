import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/education.dart';
import '../../../core/format.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/concept_chip.dart';
import '../../../core/sector_colors.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/price_flash.dart';
import '../../profile/data/profile_repository.dart';
import '../../trading/data/trading_repository.dart';
import '../data/market_repository.dart';
import '../domain/asset.dart';
import 'sparkline.dart';
import 'ticker_tape.dart';
import 'top_movers.dart';
import 'widgets.dart';

/// The market: live asset list grouped by class (with unlock gates) and the
/// news feed that explains why prices are moving.
class MarketScreen extends ConsumerWidget {
  const MarketScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Market'),
          actions: const [
            Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(child: ConceptChip(Concepts.supplyDemand)),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: 'Assets'),
            Tab(text: 'News'),
          ]),
        ),
        body: const TabBarView(children: [
          _AssetsTab(),
          _NewsTab(),
        ]),
      ),
    );
  }
}

class _AssetsTab extends ConsumerWidget {
  const _AssetsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(assetsProvider);
    final classes = ref.watch(assetClassesProvider);
    final unlocked = ref.watch(unlockedClassesProvider);

    return AsyncView(
      value: assets,
      builder: (assetList) {
        final classList = classes.value ?? const <AssetClass>[];
        final unlockedIds = unlocked.value ?? const <String>{};
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(unlockedClassesProvider);
            ref.invalidate(assetClassesProvider);
          },
          child: ListView(
            children: [
              const TickerTape(),
              const Divider(height: 1),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('Top Movers · 24h',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              const TopMovers(),
              for (final cls in classList) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    cls.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (cls.id == 'margin' && unlockedIds.contains(cls.id))
                  const Card(
                    child: ListTile(
                      leading: Text('⚡', style: TextStyle(fontSize: 22)),
                      title: Text('Broker active'),
                      subtitle: Text(
                          'Long or short any asset with the Leverage button '
                          'on its page. Respect the liquidation price.'),
                    ),
                  )
                else if (unlockedIds.contains(cls.id))
                  ...assetList
                      .where((a) => a.classId == cls.id)
                      .map((a) => _AssetTile(asset: a))
                else
                  _LockedClassCard(assetClass: cls),
              ],
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}

class _AssetTile extends ConsumerWidget {
  const _AssetTile({required this.asset});

  final Asset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sectorColor = SectorColors.of(asset.sector);
    return Card(
      child: ListTile(
        onTap: () => context.go('/market/asset/${asset.id}'),
        leading: CircleAvatar(
          backgroundColor: sectorColor.withValues(alpha: 0.22),
          child: Text(
            asset.symbol.substring(0, asset.symbol.length.clamp(0, 2)),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: sectorColor,
            ),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text('${asset.symbol} · ${asset.name}',
                  overflow: TextOverflow.ellipsis),
            ),
            if (asset.marketHours == '24_7') ...[
              const SizedBox(width: 6),
              const _MiniBadge(text: '24/7', color: AppTheme.up),
            ] else if (!asset.isMarketOpenNow) ...[
              const SizedBox(width: 6),
              const _MiniBadge(text: 'CLOSED', color: Colors.orange),
            ],
          ],
        ),
        subtitle: Text(
          asset.sector.toUpperCase(),
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: sectorColor.withValues(alpha: 0.9)),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Sparkline(assetId: asset.id),
            const SizedBox(width: 12),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                PriceFlash(
                  price: asset.currentPrice,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                ChangeBadge(
                    assetId: asset.id, currentPrice: asset.currentPrice),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Progression gate: shows the buy-in price for a locked asset class.
/// A tiny pill label (24/7, CLOSED, ...).
class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 9, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class _LockedClassCard extends ConsumerWidget {
  const _LockedClassCard({required this.assetClass});

  final AssetClass assetClass;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lock_outline),
                const SizedBox(width: 8),
                Expanded(child: Text(assetClass.description)),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: assetClass.isEnabled
                  ? () => _unlock(context, ref)
                  : null,
              child: Text(assetClass.isEnabled
                  ? 'Unlock for ${Fmt.money(assetClass.unlockCost)}'
                  : 'Coming soon'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _unlock(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final receipt = await ref
          .read(tradingRepositoryProvider)
          .purchaseAssetClassUnlock(assetClass.id);
      if (receipt.status == 'unlocked') {
        ref.invalidate(unlockedClassesProvider);
        messenger.showSnackBar(SnackBar(
            content: Text('${assetClass.name} unlocked — new markets open!')));
      } else {
        messenger.showSnackBar(SnackBar(
            content: Text('Unlock failed: ${receipt.reason ?? 'unknown'}')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Unlock failed: $error')));
    }
  }
}

class _NewsTab extends ConsumerWidget {
  const _NewsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(marketEventsProvider);
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final symbolById = {for (final a in assets) a.id: a.symbol};

    return AsyncView(
      value: events,
      builder: (eventList) {
        if (eventList.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No news yet — the market is quiet. For now.'),
            ),
          );
        }
        return ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Text('Why prices move',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  const ConceptChip(Concepts.newsMovesMarkets),
                ],
              ),
            ),
            for (final event in eventList)
              EventTile(event: event, symbol: symbolById[event.assetId]),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}
