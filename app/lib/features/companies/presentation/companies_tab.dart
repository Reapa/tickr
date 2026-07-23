import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/feedback.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/celebration.dart';
import '../../../core/widgets/countdown.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../../market/presentation/asset_detail_screen.dart' show confirmClassUnlock;
import '../../profile/data/profile_repository.dart';
import '../data/companies_repository.dart';
import '../domain/company.dart';

/// The Companies tab: a tycoon management view (own businesses + found / acquire),
/// gated behind the $250k Companies unlock. Pre-IPO these are private companies,
/// not tradeable assets — so this replaces the old market-list placeholder.
class CompaniesTab extends ConsumerWidget {
  const CompaniesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked =
        ref.watch(unlockedClassesProvider).value?.contains('companies') ?? false;
    if (!unlocked) return const _CompaniesLocked();

    final companies = ref.watch(myCompaniesProvider).value ?? const <Company>[];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const _DecisionsSection(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text('Your businesses',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        if (companies.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
                'Found a company from scratch or acquire an established one. '
                'It earns revenue you collect on the Portfolio tab, and its '
                'value builds your net worth — separately from your season score.'),
          )
        else
          for (final c in companies) _CompanyCard(company: c),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: FilledButton.icon(
            icon: const Icon(Icons.add_business),
            onPressed: () => _openFound(context, ref),
            label: const Text('Found a company'),
          ),
        ),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Acquire a business',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        const _ListingsSection(),
      ],
    );
  }

  void _openFound(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _FoundSheet(),
    );
  }
}

class _CompaniesLocked extends ConsumerWidget {
  const _CompaniesLocked();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cls = (ref.watch(assetClassesProvider).value ?? const <AssetClass>[])
        .where((c) => c.id == 'companies')
        .firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 12),
        const Icon(Icons.business_center, size: 48, color: AppTheme.gold),
        const SizedBox(height: 12),
        Text('Build a business empire',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Found companies from the ground up or acquire established ones. Grow '
          'them with strategic decisions, earn revenue while you sleep, and one '
          'day take them public. Your empire builds your wealth — on its own '
          'track, separate from the trading seasons.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        if (cls != null)
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.gold, foregroundColor: Colors.black),
            icon: const Icon(Icons.lock_open),
            onPressed: () => confirmClassUnlock(context, ref, cls),
            label: Text('Unlock Companies for ${Fmt.money(cls.unlockCost)}'),
          ),
      ],
    );
  }
}

class _CompanyCard extends ConsumerWidget {
  const _CompanyCard({required this.company});

  final Company company;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perDay = company.revenueRate / 14; // seconds_per_game_year = 14 days
    final gain = company.valueGain;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(company.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                _Pill(
                    text: company.isFounded ? 'FOUNDED' : 'ACQUIRED',
                    color: company.isFounded ? AppTheme.up : AppTheme.accent),
              ],
            ),
            const SizedBox(height: 2),
            Text('${company.industryId.toUpperCase()} · Level ${company.level}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            const SizedBox(height: 10),
            Row(
              children: [
                _Stat(label: 'Valuation', value: Fmt.moneyCompact(company.valuation)),
                const SizedBox(width: 20),
                _Stat(
                    label: 'Revenue',
                    value: '${Fmt.moneyCompact(company.revenueRate)}/yr',
                    color: AppTheme.up),
                const SizedBox(width: 20),
                _Stat(label: 'Income', value: '~${Fmt.money(perDay)}/day'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  gain >= 0
                      ? 'Up ${Fmt.money(gain)} on ${Fmt.money(company.investedBasis)} invested'
                      : 'Down ${Fmt.money(-gain)} on ${Fmt.money(company.investedBasis)} invested',
                  style: TextStyle(
                      fontSize: 12, color: AppTheme.changeColor(gain)),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _confirmSell(context, ref),
                  child: const Text('Sell'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSell(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Sell ${company.name}?'),
        content: Text(
            'Sell the business for cash at roughly its valuation (a 10% '
            'liquidity haircut applies). You lose the company and its income.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sell')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await ref.read(companiesRepositoryProvider).sell(company.id);
      if (res['status'] == 'sold') {
        messenger.showSnackBar(SnackBar(
            content: Text('Sold ${company.name} for '
                '${Fmt.money((res['proceeds'] as num).toDouble())}')));
      } else {
        messenger.showSnackBar(SnackBar(content: Text('Sale failed: ${res['status']}')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

/// Pending strategic decisions across the player's companies — the interactive
/// heart. Rendered at the top so a waiting decision is the first thing you see.
class _DecisionsSection extends ConsumerWidget {
  const _DecisionsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decisions =
        ref.watch(myCompanyDecisionsProvider).value ?? const <CompanyDecision>[];
    if (decisions.isEmpty) return const SizedBox.shrink();
    final companies = ref.watch(myCompaniesProvider).value ?? const <Company>[];
    final nameById = {for (final c in companies) c.id: c.name};
    return Column(
      children: [
        for (final d in decisions)
          _DecisionCard(decision: d, companyName: nameById[d.companyId] ?? 'Company'),
      ],
    );
  }
}

class _DecisionCard extends ConsumerStatefulWidget {
  const _DecisionCard({required this.decision, required this.companyName});

  final CompanyDecision decision;
  final String companyName;

  @override
  ConsumerState<_DecisionCard> createState() => _DecisionCardState();
}

class _DecisionCardState extends ConsumerState<_DecisionCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.decision;
    final accent = d.isEvent ? Colors.orange : AppTheme.accent;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: accent.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Pill(text: d.isEvent ? 'EVENT' : 'DECISION', color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(widget.companyName,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                ),
                Countdown(
                  target: d.expiresAt,
                  builder: (r) => Text(
                    r == Duration.zero ? 'expiring…' : '${r.inHours}h ${r.inMinutes % 60}m left',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(d.prompt,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            for (final o in d.options)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _busy ? null : () => _choose(o),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.hairline),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(o.label,
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                              if (o.blurb.isNotEmpty)
                                Text(o.blurb,
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.grey.shade500)),
                            ],
                          ),
                        ),
                        Text(
                          o.cost > 0 ? '-${Fmt.money(o.cost)}' : 'Free',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: o.cost > 0 ? AppTheme.down : AppTheme.up),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _choose(DecisionOption o) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res =
          await ref.read(companiesRepositoryProvider).decide(widget.decision.id, o.key);
      if (!mounted) return;
      final status = res['status'] as String?;
      if (status == 'ok') {
        final delta = (res['revenue_delta'] as num?)?.toDouble() ?? 0;
        if (ref.read(feedbackEnabledProvider)) {
          showCelebration(
            context,
            title: delta >= 0 ? '${o.label} paid off' : o.label,
            subtitle: delta >= 0
                ? 'Revenue ${delta > 0 ? '+' : ''}${Fmt.money(delta)}/yr'
                : 'Revenue ${Fmt.money(delta)}/yr',
            emoji: delta >= 0 ? '📈' : '📉',
          );
        }
      } else if (status == 'insufficient_cash') {
        setState(() => _busy = false);
        messenger.showSnackBar(SnackBar(
            content: Text('Not enough cash — need ${Fmt.money(
                (res['cost'] as num?)?.toDouble() ?? 0)}')));
      } else {
        setState(() => _busy = false);
        messenger.showSnackBar(SnackBar(content: Text('Could not apply ($status)')));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class _ListingsSection extends ConsumerWidget {
  const _ListingsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listings = ref.watch(companyListingsProvider);
    return listings.when(
      loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator())),
      error: (e, _) => Padding(
          padding: const EdgeInsets.all(16), child: Text('$e')),
      data: (rows) {
        if (rows.isEmpty) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('No businesses on the market right now — check back soon.'),
          );
        }
        return Column(
          children: [for (final l in rows) _ListingTile(listing: l)],
        );
      },
    );
  }
}

class _ListingTile extends ConsumerWidget {
  const _ListingTile({required this.listing});

  final CompanyListing listing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cash = ref.watch(myProfileProvider).value?.cashBalance ?? 0;
    final canAfford = cash >= listing.valuation;
    return Card(
      child: ListTile(
        title: Text(listing.name,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${listing.industryId.toUpperCase()} · Level ${listing.level} '
            '· ${Fmt.moneyCompact(listing.revenueRate)}/yr revenue'),
        trailing: FilledButton(
          onPressed: canAfford ? () => _buy(context, ref) : null,
          child: Text(Fmt.moneyCompact(listing.valuation)),
        ),
      ),
    );
  }

  Future<void> _buy(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Acquire ${listing.name}?'),
        content: Text('Buy this business for ${Fmt.money(listing.valuation)}. '
            'It starts earning ${Fmt.money(listing.revenueRate)}/yr immediately.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Acquire')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res = await ref.read(companiesRepositoryProvider).buy(listing.id);
      ref.invalidate(companyListingsProvider);
      if (res['status'] == 'bought') {
        messenger.showSnackBar(
            SnackBar(content: Text('Acquired ${listing.name}!')));
      } else {
        messenger.showSnackBar(
            SnackBar(content: Text('Purchase failed: ${res['status']}')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

/// Bottom sheet to found a new company: name (with suggestions), industry, capital.
class _FoundSheet extends ConsumerStatefulWidget {
  const _FoundSheet();

  @override
  ConsumerState<_FoundSheet> createState() => _FoundSheetState();
}

class _FoundSheetState extends ConsumerState<_FoundSheet> {
  final _name = TextEditingController();
  final _capital = TextEditingController();
  String? _industryId;
  bool _submitting = false;
  final _rng = Random();

  @override
  void dispose() {
    _name.dispose();
    _capital.dispose();
    super.dispose();
  }

  void _suggestName() {
    final pool = ref.read(companyNamePoolProvider).value ?? const [];
    if (pool.isNotEmpty) _name.text = pool[_rng.nextInt(pool.length)];
  }

  @override
  Widget build(BuildContext context) {
    final industries =
        ref.watch(companyIndustriesProvider).value ?? const <CompanyIndustry>[];
    final selected =
        industries.where((i) => i.id == _industryId).firstOrNull;
    final cash = ref.watch(myProfileProvider).value?.cashBalance ?? 0;

    // Default the name once suggestions load.
    if (_name.text.isEmpty && ref.watch(companyNamePoolProvider).hasValue) {
      _suggestName();
    }

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Found a company',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: 'Company name',
              suffixIcon: IconButton(
                icon: const Icon(Icons.casino_outlined),
                tooltip: 'Suggest a name',
                onPressed: () => setState(_suggestName),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Industry', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final ind in industries)
                ChoiceChip(
                  label: Text(ind.name),
                  selected: _industryId == ind.id,
                  onSelected: (_) => setState(() {
                    _industryId = ind.id;
                    _capital.text = ind.minCapital.toStringAsFixed(0);
                  }),
                ),
            ],
          ),
          if (selected != null) ...[
            const SizedBox(height: 8),
            Text(selected.description,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: _capital,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Startup capital',
                helperText: 'Minimum ${Fmt.money(selected.minCapital)} · '
                    'you have ${Fmt.money(cash)}',
                prefixText: '\$ ',
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _submitting || selected == null ? null : _submit,
              child: Text(_submitting ? 'Founding…' : 'Found company'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final capital = double.tryParse(_capital.text.trim()) ?? 0;
    final name = _name.text.trim();
    final industry = _industryId;
    if (industry == null || name.isEmpty || capital <= 0) return;
    setState(() => _submitting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ref
          .read(companiesRepositoryProvider)
          .found(name, industry, capital);
      if (!mounted) return;
      final status = res['status'] as String?;
      if (status == 'founded') {
        Navigator.pop(context);
        messenger.showSnackBar(SnackBar(content: Text('Founded $name!')));
      } else {
        setState(() => _submitting = false);
        messenger.showSnackBar(SnackBar(content: Text(_foundError(status, res))));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  String _foundError(String? status, Map<String, dynamic> res) => switch (status) {
        'under_min' =>
          'Needs at least ${Fmt.money((res['min'] as num).toDouble())} capital',
        'insufficient_cash' => 'Not enough cash',
        'name_taken' => 'You already have a company by that name',
        'bad_name' => 'Enter a company name',
        'locked' => 'Unlock Companies first',
        _ => 'Could not found company ($status)',
      };
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value,
            style: TextStyle(fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 9, fontWeight: FontWeight.w800, color: color)),
    );
  }
}
