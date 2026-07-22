import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/asset_icons.dart';
import '../../../core/cosmetics.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../leverage/data/leverage_repository.dart';
import '../../leverage/domain/leveraged_position.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../../profile/data/profile_repository.dart';
import '../../profile/domain/profile.dart';
import '../../profile/presentation/daily_reward_dialog.dart';
import '../data/portfolio_repository.dart';
import '../domain/holding.dart';
import '../domain/portfolio_math.dart';

/// An always-visible finances strip docked above the navigation on every tab:
/// net worth, cash (buying power), and today's P&L, plus live position chips
/// when the player holds anything. Tap the finances to open the portfolio.
class PositionsBar extends ConsumerWidget {
  const PositionsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile == null) return const SizedBox.shrink();

    final holdings = ref.watch(holdingsProvider).value ?? const <Holding>[];
    final leveraged = (ref.watch(leveragedPositionsProvider).value ?? const [])
        .where((p) => p.isOpen)
        .toList();
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final assetById = {for (final a in assets) a.id: a};

    // Today's change = net worth now vs the earliest point in the last 24h
    // (history now spans a week, so filter to the day).
    final history = ref.watch(netWorthHistoryProvider).value;
    final dayCutoff = DateTime.now().subtract(const Duration(hours: 24));
    final dayBase = history
        ?.where((p) => p.time.isAfter(dayCutoff))
        .firstOrNull ??
        history?.firstOrNull;
    final double? todayChange =
        dayBase == null ? null : profile.netWorth - dayBase.netWorth;

    final skin = equippedTickerSkin(profile.equipped);

    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: skin.background ?? AppTheme.surface,
        border: Border(
          top: BorderSide(
              color: skin.accent?.withValues(alpha: 0.6) ??
                  Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: () => context.go('/portfolio'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _Metric(
                      label: 'NET WORTH',
                      value: Fmt.moneyCompact(profile.netWorth),
                      color: skin.text),
                  const _BarDivider(),
                  _Metric(
                      label: 'CASH',
                      value: Fmt.moneyCompact(profile.cashBalance),
                      color: skin.text),
                  const _BarDivider(),
                  _Metric(
                    label: 'TODAY',
                    value: todayChange == null
                        ? '—'
                        : '${todayChange >= 0 ? '+' : ''}${Fmt.moneyCompact(todayChange)}',
                    color: todayChange == null
                        ? skin.text
                        : AppTheme.changeColor(todayChange),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.chevron_right,
                      size: 16, color: Colors.grey.shade600),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1, indent: 8, endIndent: 8),
          Expanded(
            child: (holdings.isEmpty && leveraged.isEmpty)
                ? const SizedBox.shrink()
                : ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    children: [
                      for (final holding in holdings)
                        if (assetById[holding.assetId] != null)
                          _PositionChip(
                            holding: holding,
                            asset: assetById[holding.assetId]!,
                          ),
                      for (final position in leveraged)
                        if (assetById[position.assetId] != null)
                          _LeverageChip(
                            position: position,
                            asset: assetById[position.assetId]!,
                          ),
                    ],
                  ),
          ),
          _StreakChip(profile: profile),
        ],
      ),
    );
  }
}

/// The always-visible streak flame; glows gold when today's reward is
/// unclaimed. Tap to open the daily-reward dialog.
class _StreakChip extends ConsumerWidget {
  const _StreakChip({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final claimable = profile.canClaimDaily;
    final color = claimable ? AppTheme.gold : Colors.grey.shade500;
    return InkWell(
      onTap: () => showDailyRewardDialog(context, ref),
      child: Container(
        margin: const EdgeInsets.only(right: 8, left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          color: claimable
              ? AppTheme.gold.withValues(alpha: 0.16)
              : Colors.transparent,
          border: Border.all(
              color: claimable ? AppTheme.gold.withValues(alpha: 0.5) : AppTheme.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔥', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 3),
            Text(
              claimable ? 'Claim' : '${profile.streakDays}',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w800, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// A hairline separator between finance metrics.
class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: AppTheme.hairline,
    );
  }
}

/// A stacked LABEL / value pair for the finances strip.
class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 8,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade500)),
        const SizedBox(height: 1),
        Text(value,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    );
  }
}

class _LeverageChip extends StatelessWidget {
  const _LeverageChip({required this.position, required this.asset});

  final LeveragedPosition position;
  final Asset asset;

  @override
  Widget build(BuildContext context) {
    final mark = position.isLong ? asset.bidPrice : asset.askPrice;
    final rom = position.returnOnMarginAt(mark);
    return InkWell(
      onTap: () => context.go('/market/asset/${asset.id}'),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Text('⚡${asset.symbol} ${position.leverage}x',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            Text(
              Fmt.pct(rom),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.changeColor(rom),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PositionChip extends StatelessWidget {
  const _PositionChip({required this.holding, required this.asset});

  final Holding holding;
  final Asset asset;

  @override
  Widget build(BuildContext context) {
    final ret = PortfolioMath.unrealizedReturn(holding, asset.currentPrice);
    return InkWell(
      onTap: () => context.go('/market/asset/${asset.id}'),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            AssetBadge(symbol: asset.symbol, sector: asset.sector, size: 16),
            const SizedBox(width: 5),
            Text(asset.symbol,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            Text(
              Fmt.pct(ret),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.changeColor(ret),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
