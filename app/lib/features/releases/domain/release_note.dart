/// One shipped release, newest first in [releaseNotes]. Keep this list current
/// when you ship — it's the "What's new" the app shows, and the top entry is
/// what a just-updated session highlights.
class ReleaseNote {
  const ReleaseNote({
    required this.title,
    required this.date,
    required this.highlights,
  });

  final String title;
  final String date; // ISO yyyy-mm-dd
  final List<String> highlights;
}

const releaseNotes = <ReleaseNote>[
  ReleaseNote(
    title: 'Trading & protection polish',
    date: '2026-07-22',
    highlights: [
      'Selling now pre-fills your whole position — no more hunting for “Max”.',
      'Buying defaults to unit entry, so a small fractional buy like 0.1 is one tap.',
      'Trailing stops now show their level climbing live on the asset screen.',
      'Update notices: the app tells you when a new version is out so you can refresh.',
    ],
  ),
  ReleaseNote(
    title: 'Future orders & trailing stops',
    date: '2026-07-22',
    highlights: [
      'Queue future buys: limit orders buy the dip, stop orders buy the breakout.',
      'Draggable take-profit / stop-loss straight on the chart.',
      'Trailing stops for both spot and leveraged positions.',
    ],
  ),
  ReleaseNote(
    title: 'Live competition & polish',
    date: '2026-07-21',
    highlights: [
      'Both traders’ live P&L shown during a challenge.',
      'Filter the market by gainers, losers and price, with live quotes.',
      'Tap a news headline to jump straight to the affected market.',
      'Charts remember your zoom and time range.',
    ],
  ),
];
