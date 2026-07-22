import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/brand.dart';
import '../../../core/education.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/concept_chip.dart';
import '../data/missions_repository.dart';

/// The mission board: a rotating set of daily and weekly challenges on top of
/// the permanent milestones. Missions complete automatically server-side as you
/// play; rewards land through the ledger.
class MissionsScreen extends ConsumerWidget {
  const MissionsScreen({super.key});

  static const _conceptChips = {
    'diversification': Concepts.diversification,
    'mean_reversion': Concepts.meanReversion,
    'news_reaction': Concepts.newsMovesMarkets,
    'volatility': Concepts.volatility,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final missions = ref.watch(missionsProvider);
    return Scaffold(
      appBar: tickrAppBar(title: 'Missions'),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(missionsProvider),
        child: AsyncView(
          value: missions,
          builder: (list) {
            final daily = _sorted(list.where((m) => m.cadence == 'daily'));
            final weekly = _sorted(list.where((m) => m.cadence == 'weekly'));
            final milestones =
                _sorted(list.where((m) => m.cadence == 'permanent'));
            return ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (daily.isNotEmpty)
                  _Section(
                    title: 'Daily',
                    icon: Icons.today,
                    color: AppTheme.accent,
                    resetHint: _resetLabel(daily.first.expiresAt),
                    missions: daily,
                    conceptChips: _conceptChips,
                  ),
                if (weekly.isNotEmpty)
                  _Section(
                    title: 'Weekly',
                    icon: Icons.date_range,
                    color: AppTheme.gold,
                    resetHint: _resetLabel(weekly.first.expiresAt),
                    missions: weekly,
                    conceptChips: _conceptChips,
                  ),
                _Section(
                  title: 'Milestones',
                  icon: Icons.school,
                  color: AppTheme.brand,
                  resetHint:
                      '${milestones.where((m) => m.completed).length} of ${milestones.length} done',
                  missions: milestones,
                  conceptChips: _conceptChips,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static List<MissionStatus> _sorted(Iterable<MissionStatus> it) {
    final l = it.toList()
      ..sort((a, b) {
        // Unfinished first, then by author order.
        if (a.completed != b.completed) return a.completed ? 1 : -1;
        return a.sortOrder.compareTo(b.sortOrder);
      });
    return l;
  }

  static String _resetLabel(DateTime? expiresAt) {
    if (expiresAt == null) return '';
    final d = expiresAt.difference(DateTime.now().toUtc());
    if (d.isNegative) return 'Resetting…';
    if (d.inDays >= 1) return 'Resets in ${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours >= 1) return 'Resets in ${d.inHours}h ${d.inMinutes % 60}m';
    return 'Resets in ${d.inMinutes}m';
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.color,
    required this.resetHint,
    required this.missions,
    required this.conceptChips,
  });

  final String title;
  final IconData icon;
  final Color color;
  final String resetHint;
  final List<MissionStatus> missions;
  final Map<String, Concept> conceptChips;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const Spacer(),
              if (resetHint.isNotEmpty)
                Text(resetHint,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ],
          ),
        ),
        for (final mission in missions)
          _MissionCard(mission: mission, conceptChips: conceptChips),
      ],
    );
  }
}

class _MissionCard extends StatelessWidget {
  const _MissionCard({required this.mission, required this.conceptChips});

  final MissionStatus mission;
  final Map<String, Concept> conceptChips;

  @override
  Widget build(BuildContext context) {
    final reward = StringBuffer('Reward: ${Fmt.money(mission.rewardCash)}');
    if (mission.rewardXp > 0) reward.write(' + ${mission.rewardXp} XP');
    if (mission.rewardGems > 0) reward.write(' + ${mission.rewardGems} 💎');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  mission.completed
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: mission.completed ? AppTheme.up : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    mission.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          decoration: mission.completed
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                  ),
                ),
                if (conceptChips[mission.concept] != null)
                  ConceptChip(conceptChips[mission.concept]!),
              ],
            ),
            const SizedBox(height: 8),
            Text(mission.description),
            const SizedBox(height: 8),
            Text(
              mission.completed
                  ? 'Completed ${mission.completedAt != null ? Fmt.timeAgo(mission.completedAt!) : ''}'
                  : reward.toString(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: mission.completed ? AppTheme.up : Colors.amber,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
