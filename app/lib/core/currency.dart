/// A display currency. The game economy is always USD; this only changes how
/// money is *shown* and how money-valued inputs are read. The conversion rate
/// is not a constant — it's derived from the matching in-game **forex pair's
/// live price**, so switching to Rand shows values at the simulated USD/ZAR
/// rate and drifts as that pair trades. [fallbackPerUsd] is used only until the
/// pair's price has loaded (and in tests).
class Currency {
  const Currency({
    required this.code,
    required this.name,
    required this.symbol,
    required this.fallbackPerUsd,
    this.pairSymbol,
    this.invert = false,
    this.decimals = 2,
  });

  final String code; // 'ZAR'
  final String name; // 'South African Rand'
  final String symbol; // 'R'

  /// Display units per 1 USD before the live pair price is available.
  final double fallbackPerUsd;

  /// The in-game forex asset whose live price sets the rate; null for USD.
  final String? pairSymbol;

  /// True when the pair is quoted USD-per-foreign (EURUSD 1.08): perUsd = 1/price.
  /// False when quoted foreign-per-USD (USDJPY, USDZAR): perUsd = price.
  final bool invert;

  final int decimals; // fraction digits for whole-money display

  static const usd =
      Currency(code: 'USD', name: 'US Dollar', symbol: r'$', fallbackPerUsd: 1);
}

/// Display currencies. Each non-USD entry is backed by a live forex pair that
/// exists in the market (see the forex seed + migration 25).
const kCurrencies = <Currency>[
  Currency.usd,
  Currency(code: 'EUR', name: 'Euro', symbol: '€', pairSymbol: 'EURUSD', invert: true, fallbackPerUsd: 0.922),
  Currency(code: 'GBP', name: 'British Pound', symbol: '£', pairSymbol: 'GBPUSD', invert: true, fallbackPerUsd: 0.787),
  Currency(code: 'JPY', name: 'Japanese Yen', symbol: '¥', pairSymbol: 'USDJPY', fallbackPerUsd: 148.5, decimals: 0),
  Currency(code: 'AUD', name: 'Australian Dollar', symbol: r'A$', pairSymbol: 'AUDUSD', invert: true, fallbackPerUsd: 1.527),
  Currency(code: 'ZAR', name: 'South African Rand', symbol: 'R', pairSymbol: 'USDZAR', fallbackPerUsd: 18.5),
  Currency(code: 'CAD', name: 'Canadian Dollar', symbol: r'C$', pairSymbol: 'USDCAD', fallbackPerUsd: 1.36),
  Currency(code: 'INR', name: 'Indian Rupee', symbol: '₹', pairSymbol: 'USDINR', fallbackPerUsd: 83.5),
];

Currency currencyForCode(String? code) =>
    kCurrencies.firstWhere((c) => c.code == code, orElse: () => Currency.usd);

/// Display-units-per-USD from a forex pair's live [price], honouring the pair's
/// quote convention. Falls back if the price isn't usable yet.
double perUsdFromPair(Currency currency, double price) {
  if (currency.pairSymbol == null) return 1;
  if (price <= 0) return currency.fallbackPerUsd;
  return currency.invert ? 1 / price : price;
}
