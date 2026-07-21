/// The educational layer's glossary. Concept chips across the app open these
/// explanations, so every mechanic the simulation models is also taught.
class Concept {
  const Concept({required this.term, required this.explanation});

  final String term;
  final String explanation;
}

abstract final class Concepts {
  static const marketOrder = Concept(
    term: 'Market order',
    explanation:
        'A market order buys or sells immediately at the best available '
        'price. You pay a small premium over the mid price (the spread) for '
        'that immediacy — notice how your fill price is slightly worse than '
        'the quoted price.',
  );

  static const spread = Concept(
    term: 'Spread',
    explanation:
        'The gap between the price buyers pay and sellers receive. It is the '
        'market maker\'s fee for always being willing to trade. Less-traded '
        'assets have wider spreads — check before you trade in and out '
        'quickly.',
  );

  static const volatility = Concept(
    term: 'Volatility',
    explanation:
        'How violently a price swings day to day. High-volatility assets can '
        'gain or lose a lot fast — bigger potential rewards, bigger risk. '
        'News events temporarily raise volatility.',
  );

  static const supplyDemand = Concept(
    term: 'Supply & demand',
    explanation:
        'Prices here respond to what players actually do: heavy buying '
        'pushes a price above its fair value, heavy selling pushes it below. '
        'When the crowd piles in, ask yourself who is left to buy.',
  );

  static const meanReversion = Concept(
    term: 'Mean reversion',
    explanation:
        'Prices pushed away from an asset\'s fair value tend to drift back. '
        'Panic selling often overshoots — that is why buying a news-driven '
        'dip can work. It also means chasing a spike can end badly.',
  );

  static const diversification = Concept(
    term: 'Diversification',
    explanation:
        'Spreading your money across different sectors means one piece of '
        'bad news cannot sink your whole portfolio. It is the closest thing '
        'investing has to a free lunch.',
  );

  static const newsMovesMarkets = Concept(
    term: 'News moves markets',
    explanation:
        'Earnings, scandals, and macro shocks change what an asset is worth. '
        'Watch the news feed: every price move here has a cause you can '
        'learn to read.',
  );

  static const netWorth = Concept(
    term: 'Net worth',
    explanation:
        'Your cash plus the current market value of everything you hold. '
        'Leaderboards rank net worth; seasons and challenges rank its '
        'percentage growth, so late starters still compete fairly.',
  );

  static const avgCost = Concept(
    term: 'Average cost',
    explanation:
        'The average price you paid per unit across all your buys. Selling '
        'above it locks in a real profit; a gain on paper is not a profit '
        'until you take it.',
  );
}
