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
