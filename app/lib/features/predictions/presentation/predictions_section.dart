import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../core/widgets/countdown.dart';
import '../data/predictions_repository.dart';
import '../domain/prediction.dart';

/// The prediction micro-bets on the News tab: binary "will it close higher?"
/// calls with a countdown and a variable XP payout for getting it right.
class PredictionsSection extends ConsumerWidget {
  const PredictionsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(openPredictionsProvider).value ?? const [];
    if (open.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: [
              Text('🔮 Predictions',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Call the next move — earn XP if you nail it.',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ),
            ],
          ),
        ),
        for (final p in open) _PredictionCard(item: p),
        const Divider(height: 24),
      ],
    );
  }
}

class _PredictionCard extends ConsumerWidget {
  const _PredictionCard({required this.item});

  final OpenPrediction item;

  Future<void> _call(BuildContext context, WidgetRef ref, String choice) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ref
          .read(predictionsRepositoryProvider)
          .makePrediction(item.prediction.id, choice);
      if (res['status'] != 'placed') {
        messenger.showSnackBar(
            SnackBar(content: Text('${res['reason'] ?? 'Could not place call'}')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = item.prediction;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(p.question,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                ),
                const SizedBox(width: 8),
                Countdown(
                  target: p.closesAt,
                  builder: (remaining) => _Pill(
                    icon: Icons.schedule,
                    text: remaining.inSeconds <= 0
                        ? 'closing…'
                        : _short(remaining),
                    color: remaining.inSeconds <= 15
                        ? AppTheme.gold
                        : AppTheme.accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Win ${p.rewardXp} XP if you call it right',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
            const SizedBox(height: 10),
            if (item.answered)
              _Pill(
                icon: item.myChoice == 'up'
                    ? Icons.arrow_upward
                    : Icons.arrow_downward,
                text: 'You called ${item.myChoice == 'up' ? 'Higher' : 'Lower'}',
                color:
                    item.myChoice == 'up' ? AppTheme.up : AppTheme.down,
                filled: true,
              )
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.up,
                          foregroundColor: Colors.black),
                      icon: const Icon(Icons.arrow_upward, size: 16),
                      label: const Text('Higher'),
                      onPressed: () => _call(context, ref, 'up'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.down,
                          foregroundColor: Colors.white),
                      icon: const Icon(Icons.arrow_downward, size: 16),
                      label: const Text('Lower'),
                      onPressed: () => _call(context, ref, 'down'),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _short(Duration d) {
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.text,
    required this.color,
    this.filled = false,
  });

  final IconData icon;
  final String text;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: filled ? 0.2 : 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 12, color: color)),
        ],
      ),
    );
  }
}
