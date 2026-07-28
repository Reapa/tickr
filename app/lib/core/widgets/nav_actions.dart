import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/data/auth_repository.dart';
import '../../features/fishing/data/fishing_repository.dart';
import '../../features/social/data/social_repository.dart';
import '../theme.dart';

/// The persistent top-right actions carried on every main screen: quick access
/// to Friends (with a live incoming-request badge), the Store, and Sign out.
/// Rendered as a single row so screens can drop it straight into `actions:`.
class TickrActions extends ConsumerWidget {
  const TickrActions({super.key, this.leading = const []});

  /// Page-specific actions shown to the left of the standard set.
  final List<Widget> leading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming = ref
            .watch(friendsProvider)
            .value
            ?.where((f) => f.isIncomingRequest)
            .length ??
        0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...leading,
        IconButton(
          tooltip: incoming > 0 ? 'Friends · $incoming request(s)' : 'Friends',
          icon: incoming > 0
              ? Badge(
                  label: Text('$incoming'),
                  backgroundColor: AppTheme.down,
                  child: const Icon(Icons.group_outlined),
                )
              : const Icon(Icons.group_outlined),
          onPressed: () => context.push('/friends'),
        ),
        // The Arcade badges itself when the fishing hold is full, so the pull
        // to come back is visible from whatever screen you're on.
        Consumer(
          builder: (context, ref, _) {
            final ready = ref.watch(fisheryProvider).value?.holdIsFull ?? false;
            return IconButton(
              tooltip: ready ? 'Arcade · catch ready to sell' : 'Arcade',
              icon: ready
                  ? const Badge(
                      backgroundColor: AppTheme.gold,
                      child: Icon(Icons.videogame_asset_outlined),
                    )
                  : const Icon(Icons.videogame_asset_outlined),
              onPressed: () => context.push('/arcade'),
            );
          },
        ),
        IconButton(
          tooltip: 'Store',
          icon: const Icon(Icons.storefront_outlined),
          onPressed: () => context.push('/store'),
        ),
        IconButton(
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout),
          onPressed: () => _confirmSignOut(context, ref),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text("You'll need to sign back in to keep trading."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authRepositoryProvider).signOut();
    }
  }
}
