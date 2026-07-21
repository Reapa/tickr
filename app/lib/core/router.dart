import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/presentation/sign_in_screen.dart';
import '../features/competition/presentation/compete_screen.dart';
import '../features/market/presentation/asset_detail_screen.dart';
import '../features/market/presentation/market_screen.dart';
import '../features/missions/presentation/missions_screen.dart';
import '../features/portfolio/presentation/portfolio_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/social/presentation/friends_screen.dart';
import '../features/store/presentation/store_screen.dart';
import 'shell_screen.dart';
import 'supabase_providers.dart';

/// Rebuilds router redirects when auth state changes.
class _AuthRefreshNotifier extends ChangeNotifier {
  _AuthRefreshNotifier(Stream<AuthState> stream) {
    _sub = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<AuthState> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final client = ref.watch(supabaseProvider);
  final refresh = _AuthRefreshNotifier(client.auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/market',
    refreshListenable: refresh,
    redirect: (context, state) {
      final signedIn = client.auth.currentSession != null;
      final onSignIn = state.matchedLocation == '/signin';
      if (!signedIn && !onSignIn) return '/signin';
      if (signedIn && onSignIn) return '/market';
      return null;
    },
    routes: [
      GoRoute(path: '/signin', builder: (context, state) => const SignInScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => ShellScreen(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/market',
              builder: (context, state) => const MarketScreen(),
              routes: [
                GoRoute(
                  path: 'asset/:id',
                  builder: (context, state) =>
                      AssetDetailScreen(assetId: state.pathParameters['id']!),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/portfolio',
              builder: (context, state) => const PortfolioScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/compete',
              builder: (context, state) => const CompeteScreen(),
              routes: [
                GoRoute(
                  path: 'friends',
                  builder: (context, state) => const FriendsScreen(),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/missions',
              builder: (context, state) => const MissionsScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/profile',
              builder: (context, state) => const ProfileScreen(),
              routes: [
                GoRoute(
                  path: 'store',
                  builder: (context, state) => const StoreScreen(),
                ),
              ],
            ),
          ]),
        ],
      ),
    ],
  );
});
