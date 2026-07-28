import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/back_or_home.dart';
import '../../../core/format.dart';
import '../../../core/sound.dart';
import '../../../core/theme.dart';
import '../../fishing/data/fishing_repository.dart';
import '../../slots/data/slots_repository.dart';

/// The Arcade — somewhere to go when the markets are shut, you're waiting on a
/// position, or you just want to do something that isn't a chart.
///
/// Games here are deliberately walled off from the season leaderboard: what you
/// put in becomes business capital, the same track Companies and Property sit
/// on, so nobody wins a season at a slot machine.
class ArcadeScreen extends ConsumerWidget {
  const ArcadeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fishery = ref.watch(fisheryProvider).value;
    final odds = ref.watch(slotOddsProvider).value;

    return Scaffold(
      appBar: AppBar(
        leading: const BackOrHome(),
        title: const Text('Arcade'),
        actions: const [_SoundToggle()],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Games to pass the time between trades. Nothing here counts toward '
            'your season return.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          _GameCard(
            title: 'The Fishery',
            tagline: 'Your boat fishes while you are away. Come back, sell the '
                'catch, buy a bigger boat.',
            icon: Icons.phishing,
            colors: const [Color(0xFF0E3A5C), Color(0xFF10788F)],
            // The status line is the hook: it says whether coming back is
            // worth anything right now.
            status: fishery == null
                ? null
                : fishery.holdCount == 0
                    ? 'Hold empty · ${fishery.boatName}'
                    : fishery.holdIsFull
                        ? 'HOLD FULL — ${Fmt.money(fishery.holdValue)} waiting'
                        : '${fishery.holdCount}/${fishery.holdCapacity} aboard '
                            '· ${Fmt.money(fishery.holdValue)}',
            highlight: fishery?.holdIsFull ?? false,
            // push, NOT go: `go` replaces the whole stack, which left the game
            // as the only route — no back entry, so the AppBar had no back
            // button and there was no way out of the Arcade.
            onTap: () => context.push('/arcade/fishery'),
          ),
          const SizedBox(height: 12),
          _GameCard(
            title: 'Slots',
            tagline: 'Three reels, one lever, and a payout table that is '
                'honest about the house edge.',
            icon: Icons.casino_outlined,
            colors: const [Color(0xFF3B1F5C), Color(0xFF8E3FA8)],
            status: odds == null
                ? null
                : '${(odds.rtp * 100).toStringAsFixed(0)}% RTP · '
                    'jackpot ${odds.symbols.map((s) => s.pay3).reduce(
                          (a, b) => a > b ? a : b,
                        ).toStringAsFixed(0)}×',
            onTap: () => context.push('/arcade/slots'),
          ),
        ],
      ),
    );
  }
}

class _GameCard extends StatelessWidget {
  const _GameCard({
    required this.title,
    required this.tagline,
    required this.icon,
    required this.colors,
    required this.status,
    required this.onTap,
    this.highlight = false,
  });

  final String title;
  final String tagline;
  final IconData icon;
  final List<Color> colors;
  final String? status;
  final VoidCallback? onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.55 : 1,
      child: Material(
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(icon, size: 40, color: Colors.white),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 19,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(tagline,
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 12,
                                height: 1.4)),
                        if (status != null) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: highlight
                                  ? AppTheme.gold
                                  : Colors.black.withValues(alpha: 0.28),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              status!,
                              style: TextStyle(
                                color: highlight ? Colors.black : Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (onTap != null)
                    const Icon(Icons.chevron_right, color: Colors.white70),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SoundToggle extends ConsumerWidget {
  const _SoundToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(soundEnabledProvider);
    return IconButton(
      tooltip: on ? 'Sound on' : 'Sound off',
      icon: Icon(on ? Icons.volume_up : Icons.volume_off),
      onPressed: () {
        ref.read(soundEnabledProvider.notifier).toggle();
        if (!on) Sfx.tick();
      },
    );
  }
}
