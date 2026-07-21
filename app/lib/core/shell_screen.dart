import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/leverage/data/leverage_repository.dart';
import '../features/market/data/market_repository.dart';
import '../features/portfolio/data/portfolio_repository.dart';
import '../features/portfolio/presentation/positions_bar.dart';
import '../features/profile/data/profile_repository.dart';
import '../features/profile/presentation/daily_reward_dialog.dart';
import '../features/trading/data/trigger_alerts.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets/celebration.dart';

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

  void _listenForLeveragedCloses(BuildContext context, WidgetRef ref) {
    ref.listen(leveragedClosesProvider, (previous, next) {
      final close = next.value;
      if (close == null) return;
      final symbol = (ref.read(assetsProvider).value ?? const [])
              .where((a) => a.id == close.assetId)
              .firstOrNull
              ?.symbol ??
          'position';
      final label = '${close.side == 'long' ? 'long' : 'short'} '
          '${close.leverage}x $symbol';
      final (message, color) = switch (close.closeReason) {
        'liquidation' => (
            '💥 LIQUIDATED: $label — margin lost (${Fmt.money(close.realizedPnl)})',
            AppTheme.down
          ),
        'take_profit' => (
            '🎯 Take profit: $label closed ${close.realizedPnl >= 0 ? '+' : ''}${Fmt.money(close.realizedPnl)}',
            AppTheme.up
          ),
        _ => (
            '🛡 Stop loss: $label closed ${Fmt.money(close.realizedPnl)}',
            Colors.orange
          ),
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: color,
        content: Text(message,
            style: const TextStyle(
                color: Colors.black, fontWeight: FontWeight.w600)),
      ));
    });
  }

  void _listenForLevelUp(BuildContext context, WidgetRef ref) {
    ref.listen(myProfileProvider, (previous, next) {
      final before = previous?.value?.level;
      final after = next.value?.level;
      // Only celebrate a genuine increase (skip first load / sign-in).
      if (before != null && after != null && after > before) {
        showCelebration(
          context,
          title: 'Level $after!',
          subtitle: after >= 10
              ? '100× leverage unlocked'
              : after >= 5
                  ? '50× leverage unlocked'
                  : 'Keep climbing',
          emoji: '⭐',
        );
      }
    });
  }

  /// Auto-open the daily-reward prompt once per session when it's claimable.
  void _maybePromptDaily(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final shown = ref.watch(dailyPromptShownProvider);
    if (profile != null && profile.canClaimDaily && !shown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!ref.read(dailyPromptShownProvider)) {
          ref.read(dailyPromptShownProvider.notifier).state = true;
          showDailyRewardDialog(context, ref);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _listenForTriggerFills(context, ref);
    _listenForLeveragedCloses(context, ref);
    _listenForLevelUp(context, ref);
    _maybePromptDaily(context, ref);
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
