import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../leverage/data/leverage_repository.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../../profile/data/profile_repository.dart';
import '../data/portfolio_repository.dart';
import '../domain/holding.dart';

/// How the player's net worth is composed across market types — Cash, each
/// asset class, and leveraged equity — with total unrealized P&L and market
/// exposure. Shows concentration you can't eyeball from a list of holdings.
class AllocationDonut extends ConsumerStatefulWidget {
  const AllocationDonut({super.key});

  @override
  ConsumerState<AllocationDonut> createState() => _AllocationDonutState();
}

class _Slice {
  _Slice(this.label, this.value, this.color);
  final String label;
  double value;
  final Color color;
}

const _classLabels = {
  'stocks': 'Stocks',
  'real_estate': 'Real Estate',
  'companies': 'Companies',
  'crypto': 'Crypto',
  'forex': 'Forex',
};

const _classColors = {
  'cash': Color(0xFF78909C),
  'stocks': Color(0xFF4DA3FF),
  'real_estate': Color(0xFF9575CD),
  'companies': Color(0xFF8D6E63),
  'crypto': Color(0xFFFFA726),
  'forex': Color(0xFF26C6DA),
  'leverage': Color(0xFFEC6EAD),
};

class _AllocationDonutState extends ConsumerState<AllocationDonut> {
  int? _touchedIndex;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    final holdings = ref.watch(holdingsProvider).value ?? const <Holding>[];
    final leveraged = (ref.watch(leveragedPositionsProvider).value ?? const [])
        .where((p) => p.isOpen)
        .toList();
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    if (profile == null) return const SizedBox.shrink();
    final assetById = {for (final a in assets) a.id: a};

    // Slices sum to net worth (mirrors the server's net-worth formula):
    // cash + spot holdings by class + leveraged equity.
    final byKey = <String, _Slice>{
      'cash': _Slice('Cash', profile.cashBalance, _classColors['cash']!),
    };
    var spotValue = 0.0;
    var unrealized = 0.0;
    for (final h in holdings) {
      final a = assetById[h.assetId];
      if (a == null) continue;
      final value = h.quantity * a.currentPrice;
      spotValue += value;
      unrealized += h.quantity * (a.currentPrice - h.avgCost);
      byKey.putIfAbsent(
          a.classId,
          () => _Slice(_classLabels[a.classId] ?? a.classId,
              0, _classColors[a.classId] ?? Colors.grey));
      byKey[a.classId]!.value += value;
    }
    var levNotional = 0.0;
    var levEquity = 0.0;
    for (final p in leveraged) {
      final a = assetById[p.assetId];
      if (a == null) continue;
      final mark = p.isLong ? a.bidPrice : a.askPrice;
      final pnl = p.pnlAt(mark);
      unrealized += pnl;
      levNotional += p.quantity * mark;
      levEquity += (p.margin + pnl).clamp(0, double.infinity);
    }
    if (levEquity > 0) {
      byKey['leverage'] =
          _Slice('Leverage', levEquity, _classColors['leverage']!);
    }

    final slices = byKey.values.where((s) => s.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = slices.fold(0.0, (a, b) => a + b.value);
    if (total <= 0) return const SizedBox.shrink();

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
            Text('Where your money is',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(
                  width: 140,
                  height: 140,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          sectionsSpace: 2,
                          centerSpaceRadius: 42,
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
                                radius: selected == i ? 24 : 18,
                                showTitle: false,
                              ),
                          ],
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            selected != null ? slices[selected].label : 'Net worth',
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
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                    color: s.color,
                                    borderRadius: BorderRadius.circular(2)),
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
                              Text('${(s.value / total * 100).toStringAsFixed(0)}%',
                                  style: const TextStyle(
                                      fontSize: 12, color: AppTheme.accent)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                _MiniStat(
                  label: 'Unrealized P&L',
                  value:
                      '${unrealized >= 0 ? '+' : ''}${Fmt.money(unrealized)}',
                  color: AppTheme.changeColor(unrealized),
                ),
                _MiniStat(
                  label: 'Invested',
                  value: Fmt.moneyCompact(spotValue + levEquity),
                ),
                _MiniStat(
                  label: 'Market exposure',
                  value: Fmt.moneyCompact(spotValue + levNotional),
                  hint: levNotional > 0 ? 'incl. leverage' : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(
      {required this.label, required this.value, this.color, this.hint});

  final String label;
  final String value;
  final Color? color;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
          Text(value,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: color)),
          if (hint != null)
            Text(hint!,
                style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}
