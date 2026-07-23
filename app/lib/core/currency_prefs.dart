import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/market/data/market_repository.dart';
import 'currency.dart';
import 'format.dart';
import 'prefs.dart';

/// The player's chosen display currency plus the conversion rate to use.
///
/// The rate is a **snapshot** of the currency's forex-pair price taken when the
/// currency is selected — not a live per-tick value. A live rate made every
/// money label wobble as the pair traded (a USD-steady trailing stop looked
/// like it drifted, totals stopped reconciling), so we capture the market rate
/// once and hold it steady until the player re-picks. [Fmt.current]/[Fmt.rate]
/// are kept in sync for the static formatter.
class CurrencyNotifier extends Notifier<Currency> {
  static const _kCode = 'display.currency';
  static const _kRate = 'display.currencyRate';

  @override
  Currency build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final currency = currencyForCode(prefs.getString(_kCode));
    Fmt.current = currency;
    Fmt.rate = currency.pairSymbol == null
        ? 1
        : (prefs.getDouble(_kRate) ?? currency.fallbackPerUsd);
    return currency;
  }

  /// The live rate the pair is trading at right now (for display in the picker).
  double liveRateFor(Currency currency) {
    if (currency.pairSymbol == null) return 1;
    final pair = (ref.read(assetsProvider).value ?? const [])
        .where((a) => a.symbol == currency.pairSymbol)
        .firstOrNull;
    return pair == null
        ? currency.fallbackPerUsd
        : perUsdFromPair(currency, pair.currentPrice);
  }

  void setCurrency(Currency currency) {
    final rate = liveRateFor(currency); // snapshot now, then hold steady
    ref.read(sharedPreferencesProvider)
      ..setString(_kCode, currency.code)
      ..setDouble(_kRate, rate);
    Fmt.current = currency;
    Fmt.rate = rate;
    state = currency;
  }

  /// Re-snapshot the live pair price so the held rate follows the market over
  /// time. Called on a ~5-minute timer and on app resume (see [TradingGameApp]):
  /// a fully-live rate wobbles every label per tick (the reason we snapshot at
  /// all), but a never-updating snapshot went stale — Rand stayed frozen until
  /// the player re-picked the currency. This is the middle ground. The update
  /// is silent (no re-key); tick-driven rebuilds pick up the new [Fmt.rate].
  void refreshRate() {
    if (state.pairSymbol == null) return;
    // Only update from a real live pair price. If the pair isn't loaded yet
    // (e.g. assetsProvider was just invalidated on resume), keep the last good
    // rate rather than snapping to the approximate fallback constant.
    final pair = (ref.read(assetsProvider).value ?? const [])
        .where((a) => a.symbol == state.pairSymbol)
        .firstOrNull;
    if (pair == null) return;
    final rate = perUsdFromPair(state, pair.currentPrice);
    if (rate <= 0) return;
    Fmt.rate = rate;
    ref.read(sharedPreferencesProvider).setDouble(_kRate, rate);
  }
}

final currencyProvider =
    NotifierProvider<CurrencyNotifier, Currency>(CurrencyNotifier.new);
