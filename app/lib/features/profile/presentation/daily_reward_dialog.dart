import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/celebration.dart';
import '../data/profile_repository.dart';
import '../domain/profile.dart';

/// One-shot guard so the daily prompt only auto-opens once per app session.
final dailyPromptShownProvider = StateProvider<bool>((ref) => false);

/// Reward schedule — mirrors game.daily_reward_amount() on the server.
double dailyRewardAmount(int streak) {
  final s = streak < 1 ? 1 : streak;
  final base = (200 + (s - 1) * 100).clamp(0, 1000).toDouble();
  return base + (s % 7 == 0 ? 1000 : 0);
}

Future<void> showDailyRewardDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) => const _DailyRewardDialog(),
  );
}

class _DailyRewardDialog extends ConsumerStatefulWidget {
  const _DailyRewardDialog();

  @override
  ConsumerState<_DailyRewardDialog> createState() => _DailyRewardDialogState();
}

class _DailyRewardDialogState extends ConsumerState<_DailyRewardDialog> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile == null) return const SizedBox.shrink();

    final claimable = profile.canClaimDaily;
    // The streak the player will reach by claiming now.
    final nextStreak = _nextStreak(profile);
    final displayStreak = claimable ? nextStreak : profile.streakDays;
    // Position within the current 7-day cycle (1..7).
    final cycleDay = ((displayStreak - 1) % 7) + 1;
    final cycleStart = displayStreak - cycleDay; // streak at day 0 of cycle

    return Dialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppTheme.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔥', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 6),
            Text('$displayStreak-day streak',
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800)),
            Text(
              claimable
                  ? 'Claim today and keep it alive'
                  : 'Come back tomorrow to extend it',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            ),
            const SizedBox(height: 18),
            // 7-day cycle track
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 1; i <= 7; i++)
                  _DayPip(
                    day: i,
                    reward: dailyRewardAmount(cycleStart + i),
                    state: i < cycleDay
                        ? _PipState.done
                        : (i == cycleDay && claimable)
                            ? _PipState.today
                            : _PipState.upcoming,
                    milestone: i == 7,
                  ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: claimable ? AppTheme.up : null,
                    foregroundColor: claimable ? Colors.black : null),
                onPressed: !claimable || _busy ? null : _claim,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(claimable
                        ? 'Claim ${Fmt.money(dailyRewardAmount(nextStreak))}'
                        : 'Claimed today ✓'),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(claimable ? 'Later' : 'Close'),
            ),
          ],
        ),
      ),
    );
  }

  int _nextStreak(Profile p) {
    final last = p.lastClaimDate;
    if (last == null) return 1;
    final yesterday =
        DateTime.now().toUtc().subtract(const Duration(days: 1));
    final wasYesterday = last.year == yesterday.year &&
        last.month == yesterday.month &&
        last.day == yesterday.day;
    return wasYesterday ? p.streakDays + 1 : 1;
  }

  Future<void> _claim() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final result =
          await ref.read(profileRepositoryProvider).claimDailyReward();
      if (result['status'] == 'claimed') {
        final reward = (result['reward'] as num).toDouble();
        final streak = result['streak'] as int;
        final milestone = result['milestone'] == true;
        navigator.pop();
        if (mounted) {
          showCelebration(
            context,
            title: '+${Fmt.money(reward)}',
            subtitle: milestone
                ? 'Day $streak milestone! 🔥'
                : '$streak-day streak · see you tomorrow',
            emoji: '🔥',
          );
        }
      } else {
        navigator.pop();
        messenger.showSnackBar(
            const SnackBar(content: Text('Already claimed today')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

enum _PipState { done, today, upcoming }

class _DayPip extends StatelessWidget {
  const _DayPip({
    required this.day,
    required this.reward,
    required this.state,
    required this.milestone,
  });

  final int day;
  final double reward;
  final _PipState state;
  final bool milestone;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _PipState.done => AppTheme.up,
      _PipState.today => AppTheme.gold,
      _PipState.upcoming => Colors.grey.shade600,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: state == _PipState.today
                ? AppTheme.gold.withValues(alpha: 0.18)
                : Colors.transparent,
            border: Border.all(color: color, width: state == _PipState.today ? 2 : 1),
          ),
          child: state == _PipState.done
              ? const Icon(Icons.check, size: 15, color: AppTheme.up)
              : Text(milestone ? '★' : '$day',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: color)),
        ),
        const SizedBox(height: 3),
        Text(Fmt.moneyCompact(reward),
            style: TextStyle(fontSize: 8.5, color: color)),
      ],
    );
  }
}
