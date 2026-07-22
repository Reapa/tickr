import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'currency.dart';
import 'format.dart';
import 'prefs.dart';

/// The player's chosen display currency, persisted across sessions. Also keeps
/// [Fmt.current] in sync so the static formatter converts correctly even at
/// call sites that don't watch this provider.
class CurrencyNotifier extends Notifier<Currency> {
  static const _kCode = 'display.currency';

  @override
  Currency build() {
    final code = ref.read(sharedPreferencesProvider).getString(_kCode);
    final currency = currencyForCode(code);
    Fmt.current = currency;
    return currency;
  }

  void setCurrency(Currency currency) {
    ref.read(sharedPreferencesProvider).setString(_kCode, currency.code);
    Fmt.current = currency;
    state = currency;
  }
}

final currencyProvider =
    NotifierProvider<CurrencyNotifier, Currency>(CurrencyNotifier.new);
