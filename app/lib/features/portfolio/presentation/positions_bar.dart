import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../leverage/data/leverage_repository.dart';
import '../../leverage/domain/leveraged_position.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../data/portfolio_repository.dart';
import '../domain/holding.dart';
import '../domain/portfolio_math.dart';

/// A compact, always-visible strip of open positions with live P&L,
/// docked above the navigation on every tab. Tap a chip to jump to the
/// asset; tap the summary to open the portfolio.
class PositionsBar extends ConsumerWidget {
  const PositionsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final holdings = ref.watch(holdingsProvider).value ?? const <Holding>[];
    final leveraged = (ref.watch(leveragedPositionsProvider).value ?? const [])
        .where((p) => p.isOpen)
        .toList();
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    if ((holdings.isEmpty && leveraged.isEmpty) || assets.isEmpty) {
      return const SizedBox.shrink();
    }

    final assetById = {for (final a in assets) a.id: a};
    var totalPnl = 0.0;
    for (final h in holdings) {
      final a = assetById[h.assetId];
      if (a != null) totalPnl += PortfolioMath.unrealizedPnl(h, a.currentPrice);
    }
    for (final p in leveraged) {
      final a = assetById[p.assetId];
      if (a != null) totalPnl += p.pnlAt(p.isLong ? a.bidPrice : a.askPrice);
    }

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
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
                  Icon(Icons.work_outline,
                      size: 14, color: AppTheme.changeColor(totalPnl)),
                  const SizedBox(width: 6),
                  Text(
                    '${totalPnl >= 0 ? '+' : ''}${Fmt.money(totalPnl)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.changeColor(totalPnl),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1, indent: 8, endIndent: 8),
          Expanded(
            child: ListView(
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
        ],
      ),
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
