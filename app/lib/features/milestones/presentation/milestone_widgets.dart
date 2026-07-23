import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/celebration.dart';
import '../../crates/data/crates_repository.dart';
import '../../profile/data/profile_repository.dart';
import '../data/milestones_repository.dart';
import '../domain/milestone.dart';

Color _tierColor(String tier) => switch (tier) {
      'legendary' => AppTheme.gold,
      'rare' => const Color(0xFF3EA6FF),
      _ => Colors.grey.shade400,
    };

String _tierEmoji(String tier) => switch (tier) {
      'legendary' => '🏆',
      'rare' => '🎁',
      _ => '📦',
    };

/// The player's current rank title (highest reached milestone), or "Novice".
String milestoneRank(List<Milestone> catalog, Set<int> reached) {
  Milestone? best;
  for (final m in catalog) {
    if (reached.contains(m.id) &&
        (best == null || m.sortOrder > best.sortOrder)) {
      best = m;
    }
  }
  return best?.title ?? 'Novice';
}

/// Portfolio card: progress toward the next milestone. Also the place that
/// lazily claims any milestones the player's net worth has crossed, awarding
/// the crate + XP and celebrating — so progression is always felt.
class MilestoneProgress extends ConsumerStatefulWidget {
  const MilestoneProgress({super.key});

  @override
  ConsumerState<MilestoneProgress> createState() => _MilestoneProgressState();
}

class _MilestoneProgressState extends ConsumerState<MilestoneProgress> {
  bool _claiming = false;
  double _lastClaimNw = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nw = ref.read(myProfileProvider).value?.netWorth;
      if (nw != null) _maybeClaim(nw);
    });
  }

  Future<void> _maybeClaim(double nw) async {
    if (_claiming || nw <= _lastClaimNw) return;
    final catalog = ref.read(milestonesCatalogProvider).value;
    final reached = ref.read(reachedMilestonesProvider).value;
    if (catalog == null || reached == null) return;
    // Only hit the server if something is actually claimable.
    final claimable =
        catalog.any((m) => m.netWorth <= nw && !reached.contains(m.id));
    if (!claimable) return;

    _claiming = true;
    _lastClaimNw = nw;
    try {
      final newly = await ref.read(milestonesRepositoryProvider).claim();
      if (newly.isNotEmpty && mounted) {
        final top = newly.last; // highest reached this batch
        showCelebration(
          context,
          title: top.title,
          subtitle: 'Milestone reached · ${_tierEmoji(top.crateTier)} '
              '${top.crateTier} crate${top.xp > 0 ? ' + ${top.xp} XP' : ''}',
          emoji: '🏅',
        );
        ref.invalidate(reachedMilestonesProvider);
        ref.invalidate(unopenedCratesProvider);
        ref.invalidate(myProfileProvider);
      }
    } catch (_) {
      // Transient; will retry as net worth ticks up.
    } finally {
      _claiming = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(myProfileProvider, (_, next) {
      final nw = next.value?.netWorth;
      if (nw != null) _maybeClaim(nw);
    });

    final catalog = ref.watch(milestonesCatalogProvider).value ?? const [];
    final reached = ref.watch(reachedMilestonesProvider).value ?? const {};
    final nw = ref.watch(myProfileProvider).value?.netWorth ?? 0;
    if (catalog.isEmpty) return const SizedBox.shrink();

    final next = catalog.where((m) => !reached.contains(m.id)).firstOrNull;
    if (next == null) {
      return Card(
        color: AppTheme.gold.withValues(alpha: 0.12),
        child: const ListTile(
          leading: Text('🏆', style: TextStyle(fontSize: 26)),
          title: Text('All milestones reached',
              style: TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text('You have topped the progression ladder.'),
        ),
      );
    }

    // Progress from the previous rung (or 0) to the next.
    final prev = catalog
        .where((m) => reached.contains(m.id) && m.netWorth < next.netWorth)
        .fold<double>(0, (a, m) => m.netWorth > a ? m.netWorth : a);
    final span = (next.netWorth - prev).clamp(1, double.infinity);
    final progress = ((nw - prev) / span).clamp(0.0, 1.0);
    final color = _tierColor(next.crateTier);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('NEXT MILESTONE',
                    style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.4,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade400)),
                const Spacer(),
                Text('Rank: ${milestoneRank(catalog, reached)}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.brand)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('${_tierEmoji(next.crateTier)} ',
                    style: const TextStyle(fontSize: 18)),
                Expanded(
                  child: Text(next.title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                ),
                Text(Fmt.money(next.netWorth),
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: color)),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: AppTheme.hairline,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Reward: ${next.crateTier} crate'
              '${next.rewardXp > 0 ? ' + ${next.rewardXp} XP' : ''}'
              '  ·  ${Fmt.money(nw)} / ${Fmt.money(next.netWorth)}',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade400),
            ),
          ],
        ),
      ),
    );
  }
}

/// A read-only ladder of every milestone with reached/locked state — for the
/// Profile screen.
class MilestoneLadder extends ConsumerWidget {
  const MilestoneLadder({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(milestonesCatalogProvider).value ?? const [];
    final reached = ref.watch(reachedMilestonesProvider).value ?? const {};
    if (catalog.isEmpty) return const SizedBox.shrink();
    final nextId =
        catalog.where((m) => !reached.contains(m.id)).firstOrNull?.id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Milestones',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        Card(
          child: Column(
            children: [
              for (final m in catalog)
                ListTile(
                  dense: true,
                  leading: Icon(
                    reached.contains(m.id)
                        ? Icons.check_circle
                        : m.id == nextId
                            ? Icons.radio_button_unchecked
                            : Icons.lock_outline,
                    color: reached.contains(m.id)
                        ? AppTheme.up
                        : m.id == nextId
                            ? _tierColor(m.crateTier)
                            : Colors.grey.shade600,
                    size: 20,
                  ),
                  title: Text(m.title,
                      style: TextStyle(
                          fontWeight:
                              m.id == nextId ? FontWeight.w800 : FontWeight.w500)),
                  subtitle: Text('${Fmt.money(m.netWorth)} net worth'),
                  trailing: Text(
                    '${_tierEmoji(m.crateTier)}${m.rewardXp > 0 ? ' +${m.rewardXp}xp' : ''}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
