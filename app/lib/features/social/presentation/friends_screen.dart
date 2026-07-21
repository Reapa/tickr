import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/async_view.dart';
import '../../profile/data/profile_repository.dart';
import '../data/social_repository.dart';

/// Friend management. Built on friend codes on purpose: Google/Facebook
/// logins don't expose friend lists, so the social graph never depends on
/// the identity provider.
class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    final friends = ref.watch(friendsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Friends')),
      body: ListView(
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.qr_code_2),
              title: Text(profile?.friendCode ?? '…'),
              subtitle: const Text('Your friend code — share it anywhere'),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: profile == null
                    ? null
                    : () {
                        Clipboard.setData(
                            ClipboardData(text: profile.friendCode));
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Code copied')));
                      },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: "Friend's code (e.g. TG-ABC123)",
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendRequest(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _sendRequest,
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
          AsyncView(
            value: friends,
            builder: (list) {
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No friends yet. Swap codes with someone and race them '
                    'up the leaderboard.',
                    textAlign: TextAlign.center,
                  ),
                );
              }
              return Column(
                children: [
                  for (final friend in list)
                    ListTile(
                      leading: CircleAvatar(
                          child: Text(friend.displayName
                              .substring(0, 1)
                              .toUpperCase())),
                      title: Text(friend.displayName),
                      subtitle: Text(friend.status == 'accepted'
                          ? 'Level ${friend.level} · ${Fmt.moneyCompact(friend.netWorth)}'
                          : friend.isIncomingRequest
                              ? 'Wants to be friends'
                              : 'Request sent'),
                      trailing: friend.isIncomingRequest
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.check,
                                      color: AppTheme.up),
                                  onPressed: () => _respond(friend, true),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close,
                                      color: AppTheme.down),
                                  onPressed: () => _respond(friend, false),
                                ),
                              ],
                            )
                          : null,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _sendRequest() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result =
          await ref.read(socialRepositoryProvider).sendFriendRequest(code);
      final status = result['status'] as String?;
      messenger.showSnackBar(SnackBar(
        content: Text(switch (status) {
          'pending' => 'Request sent to ${result['friend']}',
          'accepted' => 'You are now friends with ${result['friend']}!',
          _ => '${result['reason'] ?? 'Could not send request'}',
        }),
      ));
      if (status != null && status != 'rejected') {
        _code.clear();
        ref.invalidate(friendsProvider);
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $error')));
    }
  }

  Future<void> _respond(FriendEntry friend, bool accept) async {
    try {
      await ref
          .read(socialRepositoryProvider)
          .respondFriendRequest(friend.friendshipId, accept);
      ref.invalidate(friendsProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }
}
