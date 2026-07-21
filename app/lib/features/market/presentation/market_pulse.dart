import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../data/market_repository.dart';

/// The "room temperature" of the market — overall direction, how many assets
/// are up vs down, and the single most active mover. Makes the list feel like
/// a live floor the moment you open it.
class MarketPulse extends ConsumerWidget {
  const MarketPulse({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movers = ref.watch(moversProvider).value;
    if (movers == null || movers.isEmpty) return const SizedBox.shrink();

    final up = movers.where((m) => m.changePct > 0).length;
    final down = movers.where((m) => m.changePct < 0).length;
    final avg =
        movers.map((m) => m.changePct).reduce((a, b) => a + b) / movers.length;
    final top = movers.first; // biggest absolute move
    final avgColor = AppTheme.changeColor(avg);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.hairline),
        gradient: LinearGradient(
          colors: [
            avgColor.withValues(alpha: 0.10),
            AppTheme.surface,
          ],
        ),
      ),
      child: Row(
        children: [
          // Overall direction
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MARKET',
                  style: TextStyle(
                      fontSize: 8,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade500)),
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(avg >= 0 ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                      color: avgColor, size: 20),
                  Text(Fmt.pct(avg),
                      style: TextStyle(
                          color: avgColor,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ],
              ),
            ],
          ),
          const SizedBox(width: 16),
          // Gainers / losers split
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('$up up',
                        style: const TextStyle(
                            color: AppTheme.up,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                    Text('$down down',
                        style: const TextStyle(
                            color: AppTheme.down,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Row(
                    children: [
                      Expanded(
                        flex: up == 0 && down == 0 ? 1 : up,
                        child: Container(height: 5, color: AppTheme.up),
                      ),
                      Expanded(
                        flex: down,
                        child: Container(height: 5, color: AppTheme.down),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          // Most active
          InkWell(
            onTap: () => context.go('/market/asset/${top.assetId}'),
            borderRadius: BorderRadius.circular(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('MOST ACTIVE',
                    style: TextStyle(
                        fontSize: 8,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade500)),
                const SizedBox(height: 2),
                Text('${top.symbol}  ${Fmt.pct(top.changePct)}',
                    style: TextStyle(
                        color: AppTheme.changeColor(top.changePct),
                        fontWeight: FontWeight.w800,
                        fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
