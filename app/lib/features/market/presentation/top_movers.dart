import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../data/market_repository.dart';
import '../domain/market_event.dart';

/// A horizontal strip of the day's biggest gainers and losers — the pulse of
/// the market at a glance. Tap a card to open the asset.
class TopMovers extends ConsumerWidget {
  const TopMovers({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movers = ref.watch(moversProvider).value;
    if (movers == null || movers.isEmpty) return const SizedBox.shrink();

    // Biggest gainers and losers, interleaved most-extreme-first (already
    // sorted by absolute move server-side).
    final top = movers.take(8).toList();

    return SizedBox(
      height: 84,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          for (final m in top) _MoverCard(mover: m),
        ],
      ),
    );
  }
}

class _MoverCard extends StatelessWidget {
  const _MoverCard({required this.mover});

  final Mover mover;

  @override
  Widget build(BuildContext context) {
    final up = mover.changePct >= 0;
    final color = AppTheme.changeColor(mover.changePct);
    return GestureDetector(
      onTap: () => context.go('/market/asset/${mover.assetId}'),
      child: Container(
        width: 120,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [color.withValues(alpha: 0.22), AppTheme.surface],
          ),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(mover.symbol,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 14)),
            Text(Fmt.money(mover.currentPrice),
                style: Theme.of(context).textTheme.bodySmall),
            Row(
              children: [
                Icon(up ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                    color: color, size: 18),
                Text(
                  Fmt.pct(mover.changePct),
                  style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w700,
                      fontSize: 13),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
