import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/sector_colors.dart';
import '../../../core/theme.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../../profile/data/profile_repository.dart';
import '../data/portfolio_repository.dart';
import '../domain/holding.dart';

/// A donut of where the player's money actually sits: cash plus each spot
/// holding by market value, colored by sector, with net worth in the middle.
/// The trading-floor "at a glance" view of your book.
class AllocationDonut extends ConsumerStatefulWidget {
  const AllocationDonut({super.key});

  @override
  ConsumerState<AllocationDonut> createState() => _AllocationDonutState();
}

class _Slice {
  _Slice(this.label, this.value, this.color);
  final String label;
  final double value;
  final Color color;
}

class _AllocationDonutState extends ConsumerState<AllocationDonut> {
  int? _touchedIndex;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    final holdings = ref.watch(holdingsProvider).value ?? const <Holding>[];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    if (profile == null) return const SizedBox.shrink();

    final assetById = {for (final a in assets) a.id: a};
    final slices = <_Slice>[
      _Slice('Cash', profile.cashBalance, Colors.blueGrey),
      for (final h in holdings)
        if (assetById[h.assetId] != null)
          _Slice(
            assetById[h.assetId]!.symbol,
            h.quantity * assetById[h.assetId]!.currentPrice,
            SectorColors.of(assetById[h.assetId]!.sector),
          ),
    ]..removeWhere((s) => s.value <= 0);

    final total = slices.fold(0.0, (a, b) => a + b.value);
    if (total <= 0) return const SizedBox.shrink();

    // fl_chart reports -1 when the touch leaves the chart; treat anything
    // out of range as "nothing selected".
    final selected = (_touchedIndex != null &&
            _touchedIndex! >= 0 &&
            _touchedIndex! < slices.length)
        ? _touchedIndex
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Allocation',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 150,
                  height: 150,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          sectionsSpace: 2,
                          centerSpaceRadius: 46,
                          startDegreeOffset: -90,
                          pieTouchData: PieTouchData(
                            touchCallback: (event, resp) => setState(() {
                              _touchedIndex =
                                  resp?.touchedSection?.touchedSectionIndex;
                            }),
                          ),
                          sections: [
                            for (final (i, s) in slices.indexed)
                              PieChartSectionData(
                                value: s.value,
                                color: s.color,
                                radius: selected == i ? 26 : 20,
                                showTitle: false,
                              ),
                          ],
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            selected != null
                                ? slices[selected].label
                                : 'Net worth',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            selected != null
                                ? Fmt.moneyCompact(slices[selected].value)
                                : Fmt.moneyCompact(profile.netWorth),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 15),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (i, s) in slices.indexed)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: s.color,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(s.label,
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: selected == i
                                            ? FontWeight.w700
                                            : FontWeight.w400),
                                    overflow: TextOverflow.ellipsis),
                              ),
                              Text(
                                '${(s.value / total * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(
                                    fontSize: 12, color: AppTheme.accent),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
