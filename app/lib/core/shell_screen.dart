import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/competition/data/competition_repository.dart';
import '../features/competition/presentation/season_result.dart';
import '../features/crates/data/crates_repository.dart';
import '../features/leverage/data/leverage_repository.dart';
import '../features/predictions/data/predictions_repository.dart';
import '../features/market/data/market_repository.dart';
import '../features/market/domain/market_event.dart';
import '../features/portfolio/data/portfolio_repository.dart';
import '../features/portfolio/presentation/positions_bar.dart';
import '../features/profile/data/profile_repository.dart';
import '../features/profile/presentation/daily_reward_dialog.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/trading/data/trigger_alerts.dart';
import 'app_update.dart';
import 'feedback.dart';
import 'format.dart';
import 'theme.dart';
import 'tutorial.dart';
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
      final pnl = fill.realizedPnl;
      final pnlText = pnl == null
          ? ''
          : ' (${pnl >= 0 ? '+' : ''}${Fmt.money(pnl)})';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: fill.isTakeProfit ? AppTheme.up : AppTheme.down,
        content: Text(
          fill.isTakeProfit
              ? '🎯 Take profit hit — sold ${Fmt.quantity(fill.quantity)} $symbol$pnlText'
              : '🛡 Stop loss triggered — sold ${Fmt.quantity(fill.quantity)} $symbol$pnlText',
          style: const TextStyle(
              color: Colors.black, fontWeight: FontWeight.w600),
        ),
      ));
      Juice.close(context, ref,
          pnl: pnl ?? 0,
          symbol: symbol,
          headline: fill.isTakeProfit ? 'Take profit!' : null,
          sharpMultiplier: fill.xpMultiplier);
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
      Juice.close(context, ref,
          pnl: close.realizedPnl,
          symbol: symbol,
          headline: close.closeReason == 'take_profit' ? 'Sharp trade!' : null);
    });
  }

  void _listenForPredictionResults(BuildContext context, WidgetRef ref) {
    ref.listen(predictionResultsProvider, (previous, next) {
      final r = next.value;
      if (r == null) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: r.correct ? AppTheme.up : AppTheme.surfaceHigh,
        content: Text(
          r.correct
              ? '🔮 Prediction hit — +${r.awardedXp} XP'
              : '🔮 Prediction missed — better luck next call',
          style: TextStyle(
              color: r.correct ? Colors.black : Colors.white,
              fontWeight: FontWeight.w600),
        ),
      ));
    });
  }

  void _listenForRankChange(BuildContext context, WidgetRef ref) {
    ref.listen(rankSnapshotProvider, (previous, next) {
      final before = previous?.value;
      final after = next.value;
      if (before == null || after == null || after.rank >= before.rank) return;
      final passed = after.aheadOf;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppTheme.up,
        content: Text(
          passed != null
              ? '↑ You passed $passed — now #${after.rank}'
              : '↑ You climbed to #${after.rank}',
          style: const TextStyle(
              color: Colors.black, fontWeight: FontWeight.w700),
        ),
      ));
    });
  }

  void _listenForSeasonResult(BuildContext context, WidgetRef ref) {
    ref.listen(seasonResultProvider, (previous, next) {
      final result = next.value;
      if (result != null) showSeasonResult(context, result);
    });
  }

  void _listenForLevelUp(BuildContext context, WidgetRef ref) {
    ref.listen(myProfileProvider, (previous, next) {
      final before = previous?.value?.level;
      final after = next.value?.level;
      // Only celebrate a genuine increase (skip first load / sign-in).
      if (before != null && after != null && after > before) {
        if (ref.read(feedbackEnabledProvider)) HapticFeedback.heavyImpact();
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
    // First-run: pick a skill level before the app opens up.
    if (!ref.watch(tutorialProvider).onboarded) {
      return const OnboardingScreen();
    }
    _listenForTriggerFills(context, ref);
    _listenForLeveragedCloses(context, ref);
    _listenForLevelUp(context, ref);
    _listenForPredictionResults(context, ref);
    _listenForSeasonResult(context, ref);
    _listenForRankChange(context, ref);
    _maybePromptDaily(context, ref);
    final crateCount = ref.watch(unopenedCratesProvider).value?.length ?? 0;
    // Profile is the last destination (index 4); badge it when crates wait.
    Widget navIcon(int i) {
      final icon = Icon(_destinations[i].icon);
      return (i == 4 && crateCount > 0)
          ? Badge(label: Text('$crateCount'), child: icon)
          : icon;
    }
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
                for (final (i, d) in _destinations.indexed)
                  NavigationRailDestination(
                    icon: navIcon(i),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  const _MajorEventBanner(),
                  const _UpdateBanner(),
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
          const _MajorEventBanner(),
          const _UpdateBanner(),
          Expanded(child: shell),
          const PositionsBar(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: shell.goBranch,
        destinations: [
          for (final (i, d) in _destinations.indexed)
            NavigationDestination(icon: navIcon(i), label: d.label),
        ],
      ),
    );
  }
}

/// A dramatic banner for a live, rare "major world event" (war, pandemic,
/// central-bank shock…). Colour follows sentiment; tap for the full story.
/// Invisible when no major event is live.
class _MajorEventBanner extends ConsumerWidget {
  const _MajorEventBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final major = (ref.watch(marketEventsProvider).value ?? const <MarketEvent>[])
        .where((e) => e.isMajor && e.isLive)
        .toList();
    if (major.isEmpty) return const SizedBox.shrink();
    final event = major.first; // newest first
    final color = switch (event.sentiment) {
      'positive' => AppTheme.up,
      'negative' => AppTheme.down,
      _ => AppTheme.gold,
    };
    return Material(
      color: color.withValues(alpha: 0.16),
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(children: [
              const Text('📰 ', style: TextStyle(fontSize: 20)),
              Expanded(child: Text(event.headline)),
            ]),
            content: Text(event.body),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Got it')),
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
            child: Row(
              children: [
                const Text('📰', style: TextStyle(fontSize: 17)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('MAJOR',
                      style: TextStyle(
                          color: Colors.black,
                          fontSize: 9,
                          letterSpacing: 0.5,
                          fontWeight: FontWeight.w900)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(event.headline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 12.5)),
                ),
                Icon(Icons.chevron_right, size: 18, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A slim bar that appears only once a newer build has been deployed, offering
/// a one-tap refresh (and a peek at what changed). Invisible otherwise.
class _UpdateBanner extends ConsumerWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateProvider).value ?? AppUpdate.none;
    if (!update.updateAvailable) return const SizedBox.shrink();
    return Material(
      color: AppTheme.accent,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.rocket_launch, size: 18, color: Colors.black),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'A new version of Tickr is available.',
                  style: TextStyle(
                      color: Colors.black, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: () => context.push('/whats-new'),
                style: TextButton.styleFrom(foregroundColor: Colors.black),
                child: const Text("What's new"),
              ),
              FilledButton(
                onPressed: applyUpdate,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.black,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Refresh'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
