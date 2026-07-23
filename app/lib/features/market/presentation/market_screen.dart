import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../../core/asset_icons.dart';
import '../../../core/brand.dart';
import '../../../core/education.dart';
import '../../../core/format.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/concept_chip.dart';
import '../../../core/widgets/skeleton.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/price_flash.dart';
import '../../../core/widgets/tutorial_tip.dart';
import '../../companies/presentation/companies_tab.dart';
import '../../predictions/presentation/predictions_section.dart';
import '../../profile/data/profile_repository.dart';
import '../../trading/data/trading_repository.dart';
import '../data/market_repository.dart';
import '../domain/asset.dart';
import '../domain/market_event.dart';
import 'earnings_calendar.dart';
import 'market_pulse.dart';
import 'sparkline.dart';
import 'ticker_tape.dart';
import 'top_movers.dart';
import 'widgets.dart';

/// How the stock list is ordered/filtered.
enum StockSort {
  symbol('A–Z'),
  gainers('Top gainers'),
  losers('Top losers'),
  priceHigh('Price ▼'),
  priceLow('Price ▲');

  const StockSort(this.label);
  final String label;
}

final stockSortProvider = StateProvider<StockSort>((ref) => StockSort.symbol);

/// The market: separate tabs for the traditional assets, the 24/7 crypto
/// desk, the 24/5 forex desk, and the news feed that explains the moves.
class MarketScreen extends ConsumerWidget {
  const MarketScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: tickrAppBar(
          title: 'Market',
          bottom: const _CategoryTabBar(items: [
            (icon: Icons.trending_up, label: 'Stocks'),
            (icon: Icons.apartment, label: 'Real Estate'),
            (icon: Icons.business_center, label: 'Companies'),
            (icon: Icons.currency_bitcoin, label: 'Crypto'),
            (icon: Icons.currency_exchange, label: 'Forex'),
            (icon: Icons.article_outlined, label: 'News'),
          ]),
        ),
        body: const TabBarView(children: [
          _MarketList(
            classIds: {'stocks', 'margin'},
            showMovers: true,
          ),
          _MarketList(
            classIds: {'real_estate'},
            banner: '🏢 Property funds — steadier, income-style assets. '
                'Direct property ownership with weekly rental income is on '
                'the roadmap.',
          ),
          CompaniesTab(),
          _MarketList(
            classIds: {'crypto'},
            banner: '🟢 Crypto trades 24/7 — extreme volatility, big swings, '
                'no closing bell.',
          ),
          _MarketList(
            classIds: {'forex'},
            banner: '🕔 Forex trades 24/5 (closed weekends) — small moves, '
                'deep liquidity, made for leverage.',
          ),
          _NewsTab(),
        ]),
      ),
    );
  }
}

/// Modern pill-style category selector for the market desks. Driven by the
/// ambient DefaultTabController, so TabBarView stays in sync.
class _CategoryTabBar extends StatefulWidget implements PreferredSizeWidget {
  const _CategoryTabBar({required this.items});

  final List<({IconData icon, String label})> items;

  @override
  Size get preferredSize => const Size.fromHeight(58);

  @override
  State<_CategoryTabBar> createState() => _CategoryTabBarState();
}

class _CategoryTabBarState extends State<_CategoryTabBar> {
  final _scroll = ScrollController();
  TabController? _controller;

  void _onTab() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = DefaultTabController.of(context);
    if (c != _controller) {
      _controller?.removeListener(_onTab);
      _controller = c..addListener(_onTab);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTab);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = _controller?.index ?? 0;
    return SizedBox(
      height: 58,
      child: ListView.builder(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        itemCount: widget.items.length,
        itemBuilder: (context, i) {
          final selected = i == index;
          final item = widget.items[i];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => _controller?.animateTo(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: selected ? AppTheme.brandGradient : null,
                  color: selected ? null : AppTheme.surfaceHigh,
                  border: Border.all(
                      color: selected
                          ? Colors.transparent
                          : AppTheme.hairline),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                              color: AppTheme.brand.withValues(alpha: 0.3),
                              blurRadius: 10)
                        ]
                      : null,
                ),
                child: Row(
                  children: [
                    Icon(item.icon,
                        size: 16,
                        color: selected ? Colors.black : Colors.grey.shade400),
                    const SizedBox(width: 6),
                    Text(item.label,
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            color: selected
                                ? Colors.black
                                : Colors.grey.shade300)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A class-filtered market list. Shows the ticker + movers header only on the
/// main Assets tab; single-desk tabs (crypto/forex) get an intro banner.
class _MarketList extends ConsumerWidget {
  const _MarketList({
    required this.classIds,
    this.showMovers = false,
    this.banner,
  });

  final Set<String> classIds;
  final bool showMovers;
  final String? banner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(assetsProvider);
    final classes = ref.watch(assetClassesProvider);
    final unlocked = ref.watch(unlockedClassesProvider);

    // Change-per-asset (from the movers RPC) drives the gainers/losers sort.
    final changeById = {
      for (final m in ref.watch(moversProvider).value ?? const <Mover>[])
        m.assetId: m.changePct,
    };
    // Sorting/filtering is offered only on the Stocks tab (showMovers).
    final sort = showMovers ? ref.watch(stockSortProvider) : StockSort.symbol;

    List<Asset> sortAssets(List<Asset> input) {
      final list = [...input];
      switch (sort) {
        case StockSort.symbol:
          list.sort((a, b) => a.symbol.compareTo(b.symbol));
        case StockSort.gainers:
          list.sort((a, b) => (changeById[b.id] ?? -1e9)
              .compareTo(changeById[a.id] ?? -1e9));
        case StockSort.losers:
          list.sort((a, b) => (changeById[a.id] ?? 1e9)
              .compareTo(changeById[b.id] ?? 1e9));
        case StockSort.priceHigh:
          list.sort((a, b) => b.currentPrice.compareTo(a.currentPrice));
        case StockSort.priceLow:
          list.sort((a, b) => a.currentPrice.compareTo(b.currentPrice));
      }
      return list;
    }

    return AsyncView(
      value: assets,
      loading: const SkeletonList(),
      builder: (assetList) {
        final classList = classes.value
                ?.where((c) => classIds.contains(c.id))
                .toList() ??
            const <AssetClass>[];
        final unlockedIds = unlocked.value ?? const <String>{};
        final multi = classList.length > 1;
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(unlockedClassesProvider);
            ref.invalidate(assetClassesProvider);
          },
          child: ListView(
            children: [
              const TutorialTip(
                id: 'market_list',
                text: 'This is the market. Tap any asset to see its chart and '
                    'trade it. Locked classes (crypto, forex, more) unlock as '
                    'you grow your net worth.',
              ),
              if (showMovers) ...[
                const TickerTape(),
                const Divider(height: 1),
                const MarketPulse(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Top Movers · 24h',
                            style: TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13)),
                      ),
                      ConceptChip(Concepts.supplyDemand),
                    ],
                  ),
                ),
                const TopMovers(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: SizedBox(
                    height: 34,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(right: 8, left: 4),
                          child: Center(
                              child: Icon(Icons.sort, size: 16)),
                        ),
                        for (final s in StockSort.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(s.label,
                                  style: const TextStyle(fontSize: 12)),
                              selected: sort == s,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) => ref
                                  .read(stockSortProvider.notifier)
                                  .state = s,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              if (banner != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(banner!,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              for (final cls in classList) ...[
                if (multi)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(cls.name,
                        style: Theme.of(context).textTheme.titleMedium),
                  )
                else
                  const SizedBox(height: 8),
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
                  ...sortAssets(
                          assetList.where((a) => a.classId == cls.id).toList())
                      .map((a) => _AssetTile(asset: a))
                else ...[
                  _LockedClassCard(assetClass: cls),
                  // Locked classes are still browsable: show their live prices
                  // and charts so players can see what they're working toward.
                  ...assetList
                      .where((a) => a.classId == cls.id)
                      .map((a) => _AssetTile(asset: a, locked: true)),
                ],
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
  const _AssetTile({required this.asset, this.locked = false});

  final Asset asset;

  /// Browsable but not yet tradable — the asset's class is still locked. Shows
  /// a lock pill; tapping through still opens the (read-only) detail chart.
  final bool locked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: FlashOnChange(
        value: asset.currentPrice,
        borderRadius: AppTheme.radius,
        child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: () => context.go('/market/asset/${asset.id}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              AssetBadge(symbol: asset.symbol, sector: asset.sector, size: 44),
              const SizedBox(width: 12),
              // Name + sector/spread
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(asset.symbol,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 15)),
                        if (locked) ...[
                          const SizedBox(width: 6),
                          const _MiniBadge(text: 'LOCKED', color: Colors.grey),
                        ],
                        if (asset.marketHours == '24_7') ...[
                          const SizedBox(width: 6),
                          const _MiniBadge(text: '24/7', color: AppTheme.up),
                        ] else if (!asset.isMarketOpenNow) ...[
                          const SizedBox(width: 6),
                          const _MiniBadge(
                              text: 'CLOSED', color: Colors.orange),
                        ],
                      ],
                    ),
                    Text(asset.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade400)),
                    const SizedBox(height: 1),
                    Text(
                      '${asset.sector.toUpperCase()} · spread ${(asset.spread * 100).toStringAsFixed(2)}%',
                      style:
                          TextStyle(fontSize: 10.5, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Sparkline(assetId: asset.id, width: 46),
              const SizedBox(width: 12),
              // Price + change — always visible, prominent.
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  PriceFlash(
                    price: asset.currentPrice,
                    raw: asset.isForex,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                  const SizedBox(height: 3),
                  ChangeBadge(
                      assetId: asset.id, currentPrice: asset.currentPrice),
                ],
              ),
            ],
          ),
        ),
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
            const SizedBox(height: 4),
            Text(
              assetClass.isEnabled
                  ? 'Browse the live prices below — unlock to start trading.'
                  : 'Browse the live prices below — trading opens soon.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
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
        return ListView(
          children: [
            const PredictionsSection(),
            const UpcomingEarningsSection(),
            if (eventList.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                    child: Text('No news yet — the market is quiet. For now.')),
              )
            else ...[
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
            ],
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}
