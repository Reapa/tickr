import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/json.dart';
import '../../../core/supabase_providers.dart';

/// A friendship as seen from the signed-in player's side.
class FriendEntry {
  const FriendEntry({
    required this.friendshipId,
    required this.friendId,
    required this.displayName,
    required this.level,
    required this.netWorth,
    required this.status,
    required this.isIncomingRequest,
  });

  final String friendshipId;
  final String friendId;
  final String displayName;
  final int level;
  final double netWorth;
  final String status; // pending | accepted
  final bool isIncomingRequest;
}

/// Friend graph built on friend codes — deliberately independent of any
/// platform friend list (Google/Facebook don't expose them; Steam is roadmap).
class SocialRepository {
  SocialRepository(this._client);

  final SupabaseClient _client;

  Future<List<FriendEntry>> fetchFriends(String myId) async {
    final rows = await _client.from('friendships').select(
        'id, status, requested_by, '
        'a:profiles!friendships_user_a_fkey(id, display_name, level, net_worth), '
        'b:profiles!friendships_user_b_fkey(id, display_name, level, net_worth)');
    return rows.map((row) {
      final a = row['a'] as Map<String, dynamic>;
      final b = row['b'] as Map<String, dynamic>;
      final other = (a['id'] as String) == myId ? b : a;
      return FriendEntry(
        friendshipId: row['id'] as String,
        friendId: other['id'] as String,
        displayName: other['display_name'] as String,
        level: jsonInt(other['level'], 1),
        netWorth: jsonDouble(other['net_worth']),
        status: row['status'] as String,
        isIncomingRequest: row['status'] == 'pending' &&
            (row['requested_by'] as String) != myId,
      );
    }).toList()
      ..sort((x, y) => y.netWorth.compareTo(x.netWorth));
  }

  /// Live friend graph: refetches on any change to the player's friendships
  /// (RLS scopes Realtime events to rows they can see), so an accepted request
  /// or a new incoming request lands without a reload.
  Stream<List<FriendEntry>> watchFriends(String myId) {
    final controller = StreamController<List<FriendEntry>>();
    RealtimeChannel? channel;
    Timer? debounce;

    Future<void> refresh() async {
      try {
        controller.add(await fetchFriends(myId));
      } catch (error, stack) {
        controller.addError(error, stack);
      }
    }

    controller.onListen = () {
      refresh();
      channel = _client
          .channel('friendships-$myId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'friendships',
            callback: (_) {
              debounce?.cancel();
              debounce = Timer(const Duration(milliseconds: 250), refresh);
            },
          )
          .subscribe();
    };
    controller.onCancel = () {
      debounce?.cancel();
      if (channel != null) _client.removeChannel(channel!);
    };
    return controller.stream;
  }

  Future<Map<String, dynamic>> sendFriendRequest(String friendCode) =>
      _client.rpc<Map<String, dynamic>>('send_friend_request',
          params: {'p_friend_code': friendCode});

  Future<void> respondFriendRequest(String friendshipId, bool accept) =>
      _client.rpc<void>('respond_friend_request', params: {
        'p_friendship_id': friendshipId,
        'p_accept': accept,
      });
}

final socialRepositoryProvider = Provider<SocialRepository>(
  (ref) => SocialRepository(ref.watch(supabaseProvider)),
);

final friendsProvider = StreamProvider<List<FriendEntry>>((ref) {
  final myId = ref.watch(currentUserIdProvider);
  if (myId == null) return Stream.value(const <FriendEntry>[]);
  return ref.watch(socialRepositoryProvider).watchFriends(myId);
});
