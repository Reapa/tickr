import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/brand.dart';
import '../../../core/format.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/async_view.dart';
import '../../../core/widgets/skeleton.dart';
import '../../../core/widgets/trader_avatar.dart';
import '../../profile/data/profile_repository.dart';
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
      length: 5,
      child: Scaffold(
        appBar: tickrAppBar(
          title: 'Compete',
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: '🔴 Live'),
            Tab(text: 'Global'),
            Tab(text: 'Friends'),
            Tab(text: 'Season'),
            Tab(text: 'Challenges'),
          ]),
        ),
        body: const TabBarView(children: [
          _ActivityTab(),
          _GlobalTab(),
          _FriendsTab(),
          _SeasonTab(),
          _ChallengesTab(),
        ]),
      ),
    );
  }
}

/// The live "big trades" feed — social proof that the market is populated.
class _ActivityTab extends ConsumerWidget {
  const _ActivityTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(activityFeedProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(activityFeedProvider),
      child: AsyncView(
        value: feed,
        loading: const SkeletonList(),
        builder: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'No big moves yet. Make one and you might headline the feed.',
                    textAlign: TextAlign.center),
              ),
            );
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) => _ActivityRow(item: items[i]),
          );
        },
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item});

  final ActivityItem item;

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.changeColor(item.isBuySide ? 1 : -1);
    final verb = item.isLeverage
        ? '${item.side == 'long' ? 'longed' : 'shorted'} ${item.leverage}×'
        : (item.side == 'buy' ? 'bought' : 'sold');
    return ListTile(
      dense: true,
      leading: Icon(
        item.isLeverage
            ? Icons.bolt
            : (item.isBuySide ? Icons.arrow_upward : Icons.arrow_downward),
        color: item.isLeverage ? AppTheme.gold : color,
        size: 20,
      ),
      title: Text.rich(TextSpan(children: [
        TextSpan(
            text: item.trader,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        TextSpan(text: ' $verb ', style: TextStyle(color: Colors.grey.shade400)),
        TextSpan(
            text: item.symbol,
            style: TextStyle(fontWeight: FontWeight.w700, color: color)),
      ])),
      subtitle: Text(Fmt.timeAgo(item.at)),
      trailing: Text(
        Fmt.moneyCompact(item.notional),
        style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()]),
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
    final podium = entries.take(3).toList();
    final rest = entries.skip(3).toList();
    final me = entries.where((e) => e.userId == myId).firstOrNull;
    final meOnPodium = me != null && me.rank <= 3;

    return Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              _Podium(entries: podium, isPct: isPct, myId: myId),
              const SizedBox(height: 8),
              for (final entry in rest)
                _LeaderRow(entry: entry, isPct: isPct, isMe: entry.userId == myId),
              const SizedBox(height: 8),
            ],
          ),
        ),
        // Pinned "you" row so your standing is always visible.
        if (me != null && !meOnPodium)
          Container(
            decoration: BoxDecoration(
              color: AppTheme.surfaceHigh,
              border: Border(top: BorderSide(color: AppTheme.brand.withValues(alpha: 0.4))),
            ),
            child: _LeaderRow(entry: me, isPct: isPct, isMe: true),
          ),
      ],
    );
  }
}

/// A single non-podium leaderboard row.
class _LeaderRow extends StatelessWidget {
  const _LeaderRow(
      {required this.entry, required this.isPct, required this.isMe});

  final LeaderboardEntry entry;
  final bool isPct;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      selected: isMe,
      leading: SizedBox(
        width: 60,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 26,
              child: Text('#${entry.rank}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: isMe ? AppTheme.brand : Colors.grey.shade500,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            const SizedBox(width: 2),
            TraderAvatar(
              name: entry.displayName,
              equipped: entry.equipped,
              radius: 13,
              fallbackColor: isMe ? AppTheme.brand : Colors.grey.shade500,
            ),
          ],
        ),
      ),
      title: NameWithBadge(
        name: '${entry.displayName}${isMe ? ' (you)' : ''}',
        equipped: entry.equipped,
        style: TextStyle(fontWeight: isMe ? FontWeight.w800 : FontWeight.w500),
      ),
      subtitle: Text('Level ${entry.level}'),
      trailing: Text(
        isPct ? Fmt.pct(entry.value) : Fmt.moneyCompact(entry.value),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: isPct ? AppTheme.changeColor(entry.value) : null,
        ),
      ),
    );
  }
}

/// Top-3 podium — 1st centered and tallest, flanked by 2nd and 3rd.
class _Podium extends StatelessWidget {
  const _Podium({required this.entries, required this.isPct, this.myId});

  final List<LeaderboardEntry> entries;
  final bool isPct;
  final String? myId;

  @override
  Widget build(BuildContext context) {
    LeaderboardEntry? at(int rank) =>
        entries.where((e) => e.rank == rank).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
              child: _PodiumSpot(
                  entry: at(2), rank: 2, isPct: isPct, myId: myId, height: 92)),
          Expanded(
              child: _PodiumSpot(
                  entry: at(1), rank: 1, isPct: isPct, myId: myId, height: 120)),
          Expanded(
              child: _PodiumSpot(
                  entry: at(3), rank: 3, isPct: isPct, myId: myId, height: 74)),
        ],
      ),
    );
  }
}

class _PodiumSpot extends StatelessWidget {
  const _PodiumSpot({
    required this.entry,
    required this.rank,
    required this.isPct,
    required this.height,
    this.myId,
  });

  final LeaderboardEntry? entry;
  final int rank;
  final bool isPct;
  final double height;
  final String? myId;

  static const _medals = {1: '🥇', 2: '🥈', 3: '🥉'};
  static const _colors = {1: AppTheme.gold, 2: Color(0xFFB9C4D0), 3: Color(0xFFCD8E5E)};

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final color = _colors[rank]!;
    if (e == null) {
      return SizedBox(height: height + 78);
    }
    final isMe = e.userId == myId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(_medals[rank]!, style: const TextStyle(fontSize: 24)),
          const SizedBox(height: 4),
          TraderAvatar(
            name: e.displayName,
            equipped: e.equipped,
            radius: rank == 1 ? 26 : 22,
            fallbackColor: color,
          ),
          const SizedBox(height: 6),
          NameWithBadge(
            name: isMe ? 'You' : e.displayName,
            equipped: e.equipped,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
          ),
          Text(isPct ? Fmt.pct(e.value) : Fmt.moneyCompact(e.value),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: isPct ? AppTheme.changeColor(e.value) : color)),
          const SizedBox(height: 6),
          Container(
            height: height,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [color.withValues(alpha: 0.32), color.withValues(alpha: 0.06)],
              ),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            alignment: Alignment.topCenter,
            padding: const EdgeInsets.only(top: 8),
            child: Text('$rank',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w900, color: color)),
          ),
        ],
      ),
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
        loading: const SkeletonList(),
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
            _SeasonHeader(season: s),
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

/// Season banner: a countdown ring, the format, and what the top finishers win.
class _SeasonHeader extends StatelessWidget {
  const _SeasonHeader({required this.season});

  final Season season;

  @override
  Widget build(BuildContext context) {
    final total = season.endsAt.difference(season.startsAt).inSeconds;
    final elapsed = DateTime.now().difference(season.startsAt).inSeconds;
    final progress = total <= 0 ? 1.0 : (elapsed / total).clamp(0.0, 1.0);
    final rem = season.remaining;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 64,
                  height: 64,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: CircularProgressIndicator(
                          value: 1 - progress,
                          strokeWidth: 5,
                          backgroundColor: AppTheme.hairline,
                          valueColor: const AlwaysStoppedAnimation(AppTheme.gold),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('${rem.inDays}d',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 16)),
                          Text('${rem.inHours % 24}h left',
                              style: TextStyle(
                                  fontSize: 8, color: Colors.grey.shade400)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(season.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 2),
                      Text('Ranked by % return — everyone starts even',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade400)),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 22),
            Text('SEASON REWARDS',
                style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade500)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: const [
                _RewardChip(icon: '🥇', label: r'$5,000'),
                _RewardChip(icon: '🥈', label: r'$2,500'),
                _RewardChip(icon: '🥉', label: r'$1,000'),
                _RewardChip(icon: '🏆', label: 'Top 10% · exclusive frame + 100💎'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RewardChip extends StatelessWidget {
  const _RewardChip({required this.icon, required this.label});

  final String icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.gold.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.gold.withValues(alpha: 0.3)),
      ),
      child: Text('$icon  $label',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
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
    final opponent = nameById[challenge.opponentId(myId)] ?? 'Unknown trader';

    // My live return (active challenges): current net worth vs my snapshot.
    final myProfile = ref.watch(myProfileProvider).value;
    final myNw = myProfile?.netWorth;
    final myStart = challenge.myStartNw(myId);
    final myFinal =
        challenge.challengerId == myId ? challenge.challengerReturn : challenge.challengeeReturn;
    final theirFinal =
        challenge.challengerId == myId ? challenge.challengeeReturn : challenge.challengerReturn;
    final myLive = (myStart != null && myStart > 0 && myNw != null)
        ? myNw / myStart - 1
        : null;

    // Opponent's live return: their current net worth (from the friends board)
    // vs their challenge-start snapshot. Shown live so the race is honest.
    final oppId = challenge.opponentId(myId);
    final oppEntry = (ref.watch(friendsLeaderboardProvider).value ??
            const <LeaderboardEntry>[])
        .where((e) => e.userId == oppId)
        .firstOrNull;
    final oppNw = oppEntry?.value;
    final oppStart = challenge.challengerId == myId
        ? challenge.challengeeStartNw
        : challenge.challengerStartNw;
    final theirLive = (oppStart != null && oppStart > 0 && oppNw != null)
        ? oppNw / oppStart - 1
        : null;

    final iWon = challenge.winnerId == myId;
    final completed = challenge.status == 'completed';

    // Status pill
    final (pillText, pillColor) = switch (challenge.status) {
      'pending' => challenge.isIncomingFor(myId)
          ? ('INCOMING', AppTheme.gold)
          : ('SENT', Colors.grey),
      'active' => ('LIVE', AppTheme.down),
      'completed' => challenge.winnerId == null
          ? ('TIE', Colors.grey)
          : (iWon ? ('WON +\$500' , AppTheme.up) : ('LOST', AppTheme.down)),
      'declined' => ('DECLINED', Colors.grey),
      _ => ('EXPIRED', Colors.grey),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          children: [
            Row(
              children: [
                Text('${challenge.duration} head-to-head',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade400)),
                const Spacer(),
                _StatusPill(text: pillText, color: pillColor),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _Fighter(
                  name: 'You',
                  ret: completed ? myFinal : myLive,
                  highlight: completed && iWon,
                  pending: !completed && challenge.status != 'active',
                  equipped: myProfile?.equipped,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text('VS',
                      style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Colors.grey.shade600)),
                ),
                _Fighter(
                  name: opponent,
                  ret: completed ? theirFinal : theirLive,
                  highlight: completed && !iWon && challenge.winnerId != null,
                  pending: completed
                      ? false
                      : challenge.status == 'active'
                          ? theirLive == null
                          : true,
                  equipped: oppEntry?.equipped,
                ),
              ],
            ),
            if (challenge.status == 'active' && challenge.endsAt != null) ...[
              const SizedBox(height: 8),
              Text(
                  'Ends in ${_short(challenge.endsAt!.difference(DateTime.now()))} · highest % return wins',
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ],
            if (challenge.isIncomingFor(myId)) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _respond(context, ref, false),
                      child: const Text('Decline'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.up,
                          foregroundColor: Colors.black),
                      onPressed: () => _respond(context, ref, true),
                      child: const Text('Accept'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _short(Duration d) {
    if (d.isNegative) return 'now';
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m';
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

/// One side of a head-to-head card: avatar, name, and % return (or a hidden
/// placeholder while the race is live / not yet started).
class _Fighter extends StatelessWidget {
  const _Fighter({
    required this.name,
    required this.ret,
    required this.highlight,
    required this.pending,
    this.equipped,
  });

  final String name;
  final double? ret;
  final bool highlight;
  final bool pending;
  final Map<String, dynamic>? equipped;

  @override
  Widget build(BuildContext context) {
    final color = ret == null ? Colors.grey : AppTheme.changeColor(ret!);
    return Expanded(
      child: Column(
        children: [
          TraderAvatar(
            name: name,
            equipped: equipped,
            radius: 20,
            fallbackColor: highlight ? AppTheme.gold : AppTheme.surfaceHigh,
            child: highlight
                ? const Text('👑', style: TextStyle(fontSize: 18))
                : null,
          ),
          const SizedBox(height: 6),
          NameWithBadge(
              name: name,
              equipped: equipped,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 12.5)),
          const SizedBox(height: 2),
          Text(
            pending ? '—' : Fmt.pct(ret ?? 0),
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 10,
              letterSpacing: 0.5,
              fontWeight: FontWeight.w800,
              color: color)),
    );
  }
}
