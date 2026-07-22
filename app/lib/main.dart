import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/currency_prefs.dart';
import 'core/env.dart';
import 'core/prefs.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'features/leverage/data/leverage_repository.dart';
import 'features/market/data/market_repository.dart';
import 'features/portfolio/data/portfolio_repository.dart';
import 'features/profile/data/profile_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: Env.supabaseUrl,
    // Accepts either a legacy anon JWT or a new sb_publishable_... key.
    publishableKey: Env.supabaseAnonKey,
  );
  final prefs = await SharedPreferences.getInstance();
  runApp(ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: const TradingGameApp(),
  ));
}

class TradingGameApp extends ConsumerStatefulWidget {
  const TradingGameApp({super.key});

  @override
  ConsumerState<TradingGameApp> createState() => _TradingGameAppState();
}

class _TradingGameAppState extends ConsumerState<TradingGameApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _resyncLiveData);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Mobile browsers suspend the Realtime WebSocket when the tab is
  /// backgrounded or the phone locks, and postgres_changes never replays the
  /// gap — so live streams (news, prices, holdings, orders, positions, profile)
  /// could freeze until a manual refresh. Rebuilding them on resume makes
  /// returning to the app behave like that refresh.
  void _resyncLiveData() {
    ref.invalidate(marketEventsProvider);
    ref.invalidate(assetsProvider);
    ref.invalidate(holdingsProvider);
    ref.invalidate(openOrdersProvider);
    ref.invalidate(leveragedPositionsProvider);
    ref.invalidate(myProfileProvider);
  }

  @override
  Widget build(BuildContext context) {
    // Watching keeps Fmt.current in sync (set in the notifier) and re-keys the
    // subtree below so every money label re-renders in the new currency.
    final currency = ref.watch(currencyProvider);
    return MaterialApp.router(
      title: 'Tickr',
      theme: AppTheme.dark(),
      routerConfig: ref.watch(routerProvider),
      debugShowCheckedModeBanner: false,
      builder: (context, child) => KeyedSubtree(
        key: ValueKey(currency.code),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
