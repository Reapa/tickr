import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/brand.dart';
import '../../../core/education.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/concept_chip.dart';
import '../data/missions_repository.dart';

/// The educational mission board. Missions complete automatically server-side
/// as you play; rewards land in your cash balance through the ledger.
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
            final done = list.where((m) => m.completed).length;
            return ListView(
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.school, color: AppTheme.accent),
                    title: Text('$done of ${list.length} completed'),
                    subtitle: const Text(
                        'Each mission teaches a real market concept. '
                        'Complete them by trading — rewards are automatic.'),
                  ),
                ),
                for (final mission in list)
                  Card(
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
                                color: mission.completed
                                    ? AppTheme.up
                                    : Colors.grey,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  mission.title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        decoration: mission.completed
                                            ? TextDecoration.lineThrough
                                            : null,
                                      ),
                                ),
                              ),
                              if (_conceptChips[mission.concept] != null)
                                ConceptChip(_conceptChips[mission.concept]!),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(mission.description),
                          const SizedBox(height: 8),
                          Text(
                            mission.completed
                                ? 'Completed ${mission.completedAt != null ? Fmt.timeAgo(mission.completedAt!) : ''}'
                                : 'Reward: ${Fmt.money(mission.rewardCash)} + ${mission.rewardXp} XP',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: mission.completed
                                      ? AppTheme.up
                                      : Colors.amber,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }
}
