import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/currency_prefs.dart';
import 'core/env.dart';
import 'core/prefs.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'features/companies/data/companies_repository.dart';
import 'features/income/data/income_repository.dart';
import 'features/leverage/data/leverage_repository.dart';
import 'features/market/data/market_repository.dart';
import 'features/portfolio/data/portfolio_repository.dart';
import 'features/predictions/data/predictions_repository.dart';
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
  Timer? _rateRefresh;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _resyncLiveData);
    // Keep the display-currency rate current without the per-tick wobble that
    // made us snapshot it in the first place. Also refreshed on resume below.
    _rateRefresh = Timer.periodic(
      const Duration(minutes: 5),
      (_) => ref.read(currencyProvider.notifier).refreshRate(),
    );
  }

  @override
  void dispose() {
    _rateRefresh?.cancel();
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
    ref.invalidate(openPredictionsProvider);
    ref.invalidate(incomeProvider);
    ref.invalidate(myCompaniesProvider);
    ref.invalidate(myCompanyDecisionsProvider);
    // Re-snapshot the currency rate against freshly-fetched prices so a label
    // in Rand isn't stuck on a rate from before the phone locked.
    ref.read(currencyProvider.notifier).refreshRate();
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
