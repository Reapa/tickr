import '../../../core/json.dart';

/// The player's pending + lifetime passive income (dividends from stocks,
/// rent from real estate). Accrues server-side while away; swept into cash by
/// [IncomeRepository.collect].
class UserIncome {
  const UserIncome({
    required this.pendingDividends,
    required this.pendingRent,
    required this.lifetimeIncome,
  });

  factory UserIncome.fromJson(Map<String, dynamic> json) => UserIncome(
        pendingDividends: jsonDouble(json['pending_dividends']),
        pendingRent: jsonDouble(json['pending_rent']),
        lifetimeIncome: jsonDouble(json['lifetime_income']),
      );

  final double pendingDividends;
  final double pendingRent;
  final double lifetimeIncome;

  double get pendingTotal => pendingDividends + pendingRent;
  bool get hasPending => pendingTotal > 0;

  static const empty =
      UserIncome(pendingDividends: 0, pendingRent: 0, lifetimeIncome: 0);
}

/// What a Collect swept into cash — for the reveal snackbar/card.
class IncomeCollected {
  const IncomeCollected({
    required this.status,
    required this.dividends,
    required this.rent,
    required this.total,
  });

  factory IncomeCollected.fromJson(Map<String, dynamic> json) =>
      IncomeCollected(
        status: (json['status'] as String?) ?? 'empty',
        dividends: jsonDouble(json['dividends']),
        rent: jsonDouble(json['rent']),
        total: jsonDouble(json['total']),
      );

  final String status; // 'collected' | 'empty'
  final double dividends;
  final double rent;
  final double total;

  bool get collected => status == 'collected';
}
