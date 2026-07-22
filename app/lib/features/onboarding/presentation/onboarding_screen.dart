import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../core/tutorial.dart';

/// One-time welcome shown to a new trader: what Tickr is, and a skill-level
/// pick that tunes how much in-app coaching they'll get.
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 72,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [
                      AppTheme.brand.withValues(alpha: 0.9),
                      AppTheme.accent.withValues(alpha: 0.9),
                    ]),
                  ),
                  child: const Text('📈', style: TextStyle(fontSize: 34)),
                ),
                const SizedBox(height: 16),
                Text('Welcome to Tickr',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                Text(
                  'Learn to trade stocks, crypto, forex and more with a big pile '
                  'of pretend money and zero real-world risk. Build a portfolio, '
                  'climb the leaderboard, and pick up real market instincts.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: Colors.grey.shade400),
                ),
                const SizedBox(height: 24),
                Text('How much trading experience do you have?',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('This just sets how much we explain as you go — you can '
                    'change it anytime in Profile.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.grey.shade500)),
                const SizedBox(height: 12),
                for (final level in SkillLevel.values)
                  _SkillCard(
                    level: level,
                    onPick: () =>
                        ref.read(tutorialProvider.notifier).setSkillLevel(level),
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  const _SkillCard({required this.level, required this.onPick});

  final SkillLevel level;
  final VoidCallback onPick;

  static const _icons = {
    SkillLevel.beginner: Icons.spa_outlined,
    SkillLevel.intermediate: Icons.trending_up,
    SkillLevel.advanced: Icons.rocket_launch_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: onPick,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(_icons[level], color: AppTheme.brand),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(level.label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(level.blurb,
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.grey.shade400)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
