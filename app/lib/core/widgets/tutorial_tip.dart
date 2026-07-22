import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme.dart';
import '../tutorial.dart';

/// A dismissible coaching banner. Shows once per player (tracked by [id]) and
/// only when their chosen skill level is at or below [showUpTo] — so beginners
/// get the most guidance and advanced players get little to none. Renders
/// nothing when it shouldn't show, so it's safe to drop in anywhere.
class TutorialTip extends ConsumerWidget {
  const TutorialTip({
    super.key,
    required this.id,
    required this.text,
    this.showUpTo = SkillLevel.beginner,
    this.icon = Icons.lightbulb_outline,
  });

  final String id;
  final String text;
  final SkillLevel showUpTo;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(tutorialProvider).showsTip(id, showUpTo)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(
          color: AppTheme.accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: AppTheme.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: const TextStyle(fontSize: 12.5, height: 1.3)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
              tooltip: 'Got it',
              onPressed: () =>
                  ref.read(tutorialProvider.notifier).dismissTip(id),
            ),
          ],
        ),
      ),
    );
  }
}
