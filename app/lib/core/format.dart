import 'package:intl/intl.dart';

import 'currency.dart';

/// Shared number formatting for the whole app.
///
/// Money is stored and reasoned about in USD everywhere; [Fmt] converts to the
/// player's chosen display [current] currency at the point of display, and
/// [toUsd] converts money-valued *inputs* back before they hit the server.
abstract final class Fmt {
  /// The active display currency. Set from `currencyProvider`; defaults to USD
  /// so formatting works before the preference loads (and in tests).
  static Currency current = Currency.usd;

  /// Display-units per 1 USD. A snapshot of the currency's forex-pair price
  /// taken when the currency is chosen (see `currencyProvider`), then held
  /// steady so labels don't wobble every tick. 1 for USD.
  static double rate = 1;

  static final NumberFormat _qty = NumberFormat('#,##0.####');

  /// Convert a USD amount to the display currency.
  static num _conv(num usd) => usd * rate;

  /// Convert a value typed in the display currency back to USD.
  static num toUsd(num display) => rate == 0 ? display : display / rate;

  /// The active currency symbol, e.g. r'$' or 'R' — for input prefixes.
  static String get symbol => current.symbol;

  static String _grouped(num value, int decimals) => NumberFormat(
        decimals > 0 ? '#,##0.${'0' * decimals}' : '#,##0',
      ).format(value);

  static String money(num value) =>
      '${current.symbol}${_grouped(_conv(value), current.decimals)}';

  /// $1.2M-style for leaderboards and tight spaces.
  static String moneyCompact(num value) =>
      NumberFormat.compactCurrency(symbol: current.symbol).format(_conv(value));

  static String quantity(num value) => _qty.format(value);

  /// A forex quote (e.g. EUR/USD, USD/ZAR) — a ratio between two currencies, so
  /// it is NEVER currency-converted and carries no money symbol. Adaptive
  /// decimals keep small ratios legible.
  static String quote(num value) {
    final a = value.abs();
    final d = a >= 100 ? 2 : (a >= 1 ? 4 : 5);
    return NumberFormat('#,##0.${'0' * d}').format(value);
  }

  /// Number of decimal places that keeps a price meaningful at its magnitude —
  /// so slow movers (a $12 stock, a $0.85 forex pair) don't collapse to whole
  /// numbers that hide every tick of movement. Judged on the *converted* value
  /// so the decimals still fit the currency being shown.
  static int _priceDecimals(num value) {
    final a = value.abs();
    if (a >= 1000) return 2;
    if (a >= 1) return 2;
    if (a >= 0.01) return 4;
    return 6;
  }

  /// Full-precision price with adaptive decimals — for candle tooltips and
  /// anywhere the exact level matters. e.g. 12.034 -> "$12.03", 0.8543 -> "$0.8543".
  static String price(num value) {
    final v = _conv(value);
    return '${current.symbol}${_grouped(v, _priceDecimals(v))}';
  }

  /// Compact, decimal-aware price for chart axes: large values stay short
  /// ($60.0K) while sub-$1000 prices keep the decimals that reveal movement.
  static String priceAxis(num value) {
    if (_conv(value).abs() >= 1000) return moneyCompact(value);
    return price(value);
  }

  /// Signed percentage from a fraction: 0.0523 -> "+5.23%". Currency-agnostic.
  static String pct(num fraction) {
    final value = fraction * 100;
    final sign = value >= 0 ? '+' : '';
    return '$sign${value.toStringAsFixed(2)}%';
  }

  static String timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
