import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/market/data/market_repository.dart';
import '../features/portfolio/data/portfolio_repository.dart';
import '../features/portfolio/presentation/positions_bar.dart';
import '../features/trading/data/trigger_alerts.dart';
import 'format.dart';
import 'theme.dart';

/// App chrome: bottom navigation on phones, navigation rail on wide screens
/// (desktop / web / tablets). The five tabs are independent stateful stacks.
/// Also hosts app-wide listeners (TP/SL fill toasts).
class ShellScreen extends ConsumerWidget {
  const ShellScreen({super.key, required this.shell});

  final StatefulNavigationShell shell;

  void _listenForTriggerFills(BuildContext context, WidgetRef ref) {
    ref.listen(triggerFillsProvider, (previous, next) {
      final fill = next.value;
      if (fill == null) return;
      final symbol = (ref.read(assetsProvider).value ?? const [])
              .where((a) => a.id == fill.assetId)
              .firstOrNull
              ?.symbol ??
          'position';
      ref.invalidate(openOrdersProvider);
      ref.invalidate(recentOrdersProvider);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: fill.isTakeProfit ? AppTheme.up : AppTheme.down,
        content: Text(
          fill.isTakeProfit
              ? '🎯 Take profit hit — sold ${Fmt.quantity(fill.quantity)} $symbol'
              : '🛡 Stop loss triggered — sold ${Fmt.quantity(fill.quantity)} $symbol',
          style: const TextStyle(
              color: Colors.black, fontWeight: FontWeight.w600),
        ),
      ));
    });
  }

  static const _destinations = [
    (icon: Icons.candlestick_chart_outlined, label: 'Market'),
    (icon: Icons.pie_chart_outline, label: 'Portfolio'),
    (icon: Icons.emoji_events_outlined, label: 'Compete'),
    (icon: Icons.school_outlined, label: 'Missions'),
    (icon: Icons.person_outline, label: 'Profile'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _listenForTriggerFills(context, ref);
    final wide = MediaQuery.sizeOf(context).width >= 800;
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: shell.currentIndex,
              onDestinationSelected: shell.goBranch,
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: shell),
                  const PositionsBar(),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: shell),
          const PositionsBar(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: shell.goBranch,
        destinations: [
          for (final d in _destinations)
            NavigationDestination(icon: Icon(d.icon), label: d.label),
        ],
      ),
    );
  }
}
