import 'package:intl/intl.dart';

/// Shared number formatting for the whole app.
abstract final class Fmt {
  static final NumberFormat _money = NumberFormat.currency(symbol: r'$');
  static final NumberFormat _moneyCompact =
      NumberFormat.compactCurrency(symbol: r'$');
  static final NumberFormat _qty = NumberFormat('#,##0.####');

  static String money(num value) => _money.format(value);

  /// $1.2M-style for leaderboards and tight spaces.
  static String moneyCompact(num value) => _moneyCompact.format(value);

  static String quantity(num value) => _qty.format(value);

  /// Number of decimal places that keeps a price meaningful at its magnitude —
  /// so slow movers (a $12 stock, a $0.85 forex pair) don't collapse to whole
  /// numbers that hide every tick of movement.
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
    final d = _priceDecimals(value);
    return NumberFormat('\$#,##0.${'0' * d}').format(value);
  }

  /// Compact, decimal-aware price for chart axes: large values stay short
  /// ($60.0K) while sub-$1000 prices keep the decimals that reveal movement.
  static String priceAxis(num value) {
    if (value.abs() >= 1000) return moneyCompact(value);
    return price(value);
  }

  /// Signed percentage from a fraction: 0.0523 -> "+5.23%".
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
