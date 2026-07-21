import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/async_view.dart';
import '../../social/data/social_repository.dart';
import '../data/competition_repository.dart';

/// All three competition modes in one place: the persistent global
/// leaderboard (with a friends filter), the resetting season race, and
/// head-to-head friend challenges.
class CompeteScreen extends ConsumerWidget {
  const CompeteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Compete'),
          actions: [
            IconButton(
              icon: const Icon(Icons.group_add_outlined),
              tooltip: 'Friends',
              onPressed: () => context.go('/compete/friends'),
            ),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Global'),
            Tab(text: 'Friends'),
            Tab(text: 'Season'),
            Tab(text: 'Challenges'),
          ]),
        ),
        body: const TabBarView(children: [
          _GlobalTab(),
          _FriendsTab(),
          _SeasonTab(),
          _ChallengesTab(),
        ]),
      ),
    );
  }
}

class _LeaderboardList extends ConsumerWidget {
  const _LeaderboardList({required this.entries, required this.isPct});

  final List<LeaderboardEntry> entries;
  final bool isPct;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myId = ref.watch(currentUserIdProvider);
    if (entries.isEmpty) {
      return const Center(child: Text('Nobody here yet.'));
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final isMe = entry.userId == myId;
        return ListTile(
          selected: isMe,
          leading: _RankBadge(rank: entry.rank),
          title: Text(
            '${entry.displayName}${isMe ? ' (you)' : ''}',
            style: TextStyle(fontWeight: isMe ? FontWeight.w700 : null),
          ),
          subtitle: Text('Level ${entry.level}'),
          trailing: Text(
            isPct ? Fmt.pct(entry.value) : Fmt.moneyCompact(entry.value),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: isPct ? AppTheme.changeColor(entry.value) : null,
            ),
          ),
        );
      },
    );
  }
}

class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) {
    final medal = switch (rank) {
      1 => '🥇',
      2 => '🥈',
      3 => '🥉',
      _ => null,
    };
    return CircleAvatar(
      radius: 16,
      child: Text(medal ?? '$rank', style: const TextStyle(fontSize: 13)),
    );
  }
}

class _GlobalTab extends ConsumerWidget {
  const _GlobalTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(globalLeaderboardProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(globalLeaderboardProvider),
      child: AsyncView(
        value: board,
        builder: (entries) =>
            _LeaderboardList(entries: entries, isPct: false),
      ),
    );
  }
}

class _FriendsTab extends ConsumerWidget {
  const _FriendsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(friendsLeaderboardProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(friendsLeaderboardProvider),
      child: AsyncView(
        value: board,
        builder: (entries) => entries.length <= 1
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'Just you so far. Add friends with their friend code '
                      'to race them directly.'),
                ),
              )
            : _LeaderboardList(entries: entries, isPct: false),
      ),
    );
  }
}

class _SeasonTab extends ConsumerWidget {
  const _SeasonTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final season = ref.watch(activeSeasonProvider);
    return AsyncView(
      value: season,
      builder: (s) {
        if (s == null) {
          return const Center(child: Text('No active season right now.'));
        }
        final board = ref.watch(seasonLeaderboardProvider(s.id));
        return Column(
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.emoji_events, color: Colors.amber),
                title: Text(s.name),
                subtitle: Text(
                  'Ranked by % return · ends in ${s.remaining.inDays}d '
                  '${s.remaining.inHours % 24}h · top 10% win an exclusive '
                  'cosmetic',
                ),
              ),
            ),
            Expanded(
              child: AsyncView(
                value: board,
                builder: (entries) =>
                    _LeaderboardList(entries: entries, isPct: true),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ChallengesTab extends ConsumerWidget {
  const _ChallengesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final challenges = ref.watch(challengesProvider);
    final friends = ref.watch(friendsProvider).value ?? const <FriendEntry>[];
    final myId = ref.watch(currentUserIdProvider) ?? '';
    final nameById = {for (final f in friends) f.friendId: f.displayName};

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateChallenge(context, ref, friends),
        icon: const Icon(Icons.sports_kabaddi),
        label: const Text('Challenge'),
      ),
      body: AsyncView(
        value: challenges,
        builder: (list) {
          if (list.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No challenges yet. Pick a friend and race their '
                    '% return over 24 hours or 7 days.'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [for (final c in list) _ChallengeTile(c, myId, nameById)],
          );
        },
      ),
    );
  }

  Future<void> _showCreateChallenge(
    BuildContext context,
    WidgetRef ref,
    List<FriendEntry> friends,
  ) async {
    final accepted = friends.where((f) => f.status == 'accepted').toList();
    if (accepted.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add a friend first — challenges are head-to-head.')));
      return;
    }
    FriendEntry opponent = accepted.first;
    var duration = '24h';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('New challenge'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<FriendEntry>(
                initialValue: opponent,
                decoration: const InputDecoration(labelText: 'Opponent'),
                items: [
                  for (final f in accepted)
                    DropdownMenuItem(value: f, child: Text(f.displayName)),
                ],
                onChanged: (f) => setState(() => opponent = f ?? opponent),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: '24h', label: Text('24 hours')),
                  ButtonSegment(value: '7d', label: Text('7 days')),
                ],
                selected: {duration},
                onSelectionChanged: (s) => setState(() => duration = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Send challenge')),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      final result = await ref
          .read(competitionRepositoryProvider)
          .createChallenge(opponent.friendId, duration);
      if (context.mounted && result['status'] == 'rejected') {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${result['reason']}')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Challenge failed: $error')));
      }
    }
  }
}

class _ChallengeTile extends ConsumerWidget {
  const _ChallengeTile(this.challenge, this.myId, this.nameById);

  final Challenge challenge;
  final String myId;
  final Map<String, String> nameById;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opponent =
        nameById[challenge.opponentId(myId)] ?? 'Unknown trader';
    final iAmChallenger = challenge.challengerId == myId;
    final myReturn = iAmChallenger
        ? challenge.challengerReturn
        : challenge.challengeeReturn;
    final theirReturn = iAmChallenger
        ? challenge.challengeeReturn
        : challenge.challengerReturn;

    final subtitle = switch (challenge.status) {
      'pending' => challenge.isIncomingFor(myId)
          ? 'Incoming challenge — accept?'
          : 'Waiting for $opponent to accept',
      'active' =>
        'Live · ends ${challenge.endsAt != null ? Fmt.timeAgo(challenge.endsAt!).replaceAll(' ago', '') : ''} · highest % return wins',
      'completed' => challenge.winnerId == null
          ? 'Tie! You: ${Fmt.pct(myReturn ?? 0)} · $opponent: ${Fmt.pct(theirReturn ?? 0)}'
          : challenge.winnerId == myId
              ? 'You won! ${Fmt.pct(myReturn ?? 0)} vs ${Fmt.pct(theirReturn ?? 0)} (+\$500)'
              : '$opponent won: ${Fmt.pct(theirReturn ?? 0)} vs ${Fmt.pct(myReturn ?? 0)}',
      'declined' => 'Declined',
      _ => 'Expired',
    };

    return Card(
      child: ListTile(
        leading: Icon(
          switch (challenge.status) {
            'active' => Icons.timer,
            'completed' => challenge.winnerId == myId
                ? Icons.emoji_events
                : Icons.sentiment_dissatisfied,
            _ => Icons.hourglass_empty,
          },
          color: challenge.status == 'completed' && challenge.winnerId == myId
              ? Colors.amber
              : null,
        ),
        title: Text('vs $opponent · ${challenge.duration}'),
        subtitle: Text(subtitle),
        trailing: challenge.isIncomingFor(myId)
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.check, color: AppTheme.up),
                    onPressed: () => _respond(context, ref, true),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppTheme.down),
                    onPressed: () => _respond(context, ref, false),
                  ),
                ],
              )
            : null,
      ),
    );
  }

  Future<void> _respond(
      BuildContext context, WidgetRef ref, bool accept) async {
    try {
      await ref
          .read(competitionRepositoryProvider)
          .respondChallenge(challenge.id, accept);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }
}
