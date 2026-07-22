/// A display currency. The game economy is always denominated in USD — this
/// only changes how money is *shown* and how money-valued inputs are read, via
/// a fixed conversion (`perUsd` display units per 1 USD). Switching currency
/// never changes anyone's actual wealth or the simulation.
class Currency {
  const Currency({
    required this.code,
    required this.name,
    required this.symbol,
    required this.perUsd,
    this.decimals = 2,
  });

  final String code; // ISO-ish code, e.g. 'ZAR'
  final String name; // 'South African Rand'
  final String symbol; // 'R'
  final double perUsd; // display units per 1 USD (USD = 1)
  final int decimals; // fraction digits for whole-money display

  static const usd =
      Currency(code: 'USD', name: 'US Dollar', symbol: r'$', perUsd: 1);
}

/// Supported display currencies with a fixed rate snapshot (display per 1 USD).
/// Approximate on purpose — the market itself is simulated, so a stable
/// conversion is more consistent than chasing live FX. Edit freely.
const kCurrencies = <Currency>[
  Currency(code: 'USD', name: 'US Dollar', symbol: r'$', perUsd: 1),
  Currency(code: 'ZAR', name: 'South African Rand', symbol: 'R', perUsd: 18.5),
  Currency(code: 'EUR', name: 'Euro', symbol: '€', perUsd: 0.92),
  Currency(code: 'GBP', name: 'British Pound', symbol: '£', perUsd: 0.79),
  Currency(code: 'JPY', name: 'Japanese Yen', symbol: '¥', perUsd: 157, decimals: 0),
  Currency(code: 'AUD', name: 'Australian Dollar', symbol: r'A$', perUsd: 1.52),
  Currency(code: 'CAD', name: 'Canadian Dollar', symbol: r'C$', perUsd: 1.36),
  Currency(code: 'INR', name: 'Indian Rupee', symbol: '₹', perUsd: 83.5),
  Currency(code: 'NGN', name: 'Nigerian Naira', symbol: '₦', perUsd: 1550, decimals: 0),
  Currency(code: 'BRL', name: 'Brazilian Real', symbol: r'R$', perUsd: 5.4),
];

Currency currencyForCode(String? code) =>
    kCurrencies.firstWhere((c) => c.code == code, orElse: () => Currency.usd);
