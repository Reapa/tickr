import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/brand.dart';
import '../../../core/cosmetics.dart';
import '../../../core/currency.dart';
import '../../../core/currency_prefs.dart';
import '../../../core/feedback.dart';
import '../../crates/presentation/crate_reveal.dart';
import '../../../core/tutorial.dart';
import '../../../core/widgets/trader_avatar.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';
import '../../market/data/market_repository.dart';
import '../../market/domain/asset.dart';
import '../../trading/data/trading_repository.dart';
import '../data/profile_repository.dart';
import '../domain/profile.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final classes = ref.watch(assetClassesProvider).value ?? const <AssetClass>[];
    final unlocked = ref.watch(unlockedClassesProvider).value ?? const <String>{};

    return Scaffold(
      appBar: tickrAppBar(title: 'Profile'),
      body: profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // Trader card
                Card(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppTheme.brand.withValues(alpha: 0.16),
                          AppTheme.surface,
                          AppTheme.accent.withValues(alpha: 0.10),
                        ],
                      ),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            _LevelRingAvatar(profile: profile),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(profile.displayName,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleLarge
                                                ?.copyWith(
                                                    fontWeight: FontWeight.w800),
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                      if (equippedBadge(profile.equipped) !=
                                          null) ...[
                                        const SizedBox(width: 5),
                                        Text(equippedBadge(profile.equipped)!,
                                            style:
                                                const TextStyle(fontSize: 18)),
                                      ],
                                      IconButton(
                                        icon: const Icon(Icons.edit, size: 15),
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => _editName(
                                            context, ref, profile.displayName),
                                      ),
                                    ],
                                  ),
                                  Text('Level ${profile.level} · ${profile.xp} XP',
                                      style: TextStyle(
                                          color: Colors.grey.shade400,
                                          fontSize: 13)),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      _TinyChip(
                                          icon: Icons.tag,
                                          label: profile.friendCode),
                                      const SizedBox(width: 8),
                                      _TinyChip(
                                          icon: Icons.local_fire_department,
                                          label: '${profile.streakDays}d',
                                          color: AppTheme.gold),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                // Career stat grid
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      Row(children: [
                        _StatTile(label: 'NET WORTH', value: Fmt.moneyCompact(profile.netWorth)),
                        _StatTile(label: 'CASH', value: Fmt.moneyCompact(profile.cashBalance)),
                        _StatTile(label: 'GEMS', value: '${profile.premiumBalance}', color: AppTheme.accent),
                      ]),
                      Row(children: [
                        _StatTile(label: 'STREAK', value: '${profile.streakDays}d', color: AppTheme.gold),
                        _StatTile(label: 'BEST STREAK', value: '${profile.longestStreak}d'),
                        _StatTile(label: 'LEVEL', value: '${profile.level}', color: AppTheme.brand),
                      ]),
                    ],
                  ),
                ),
                const CratesCard(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('Progression',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                for (final cls in classes)
                  _ProgressionTile(
                    assetClass: cls,
                    isUnlocked: unlocked.contains(cls.id),
                    cash: profile.cashBalance,
                  ),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.currency_exchange),
                    title: const Text('Display currency'),
                    subtitle: Text(
                        '${ref.watch(currencyProvider).name} · shows all values '
                        'in ${ref.watch(currencyProvider).code}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pickCurrency(context, ref),
                  ),
                ),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.school_outlined),
                    title: const Text('Guidance & tutorial'),
                    subtitle: Text(
                        'Coaching: ${ref.watch(tutorialProvider).skillLevel?.label ?? 'not set'}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _tutorialSettings(context, ref),
                  ),
                ),
                Card(
                  child: SwitchListTile(
                    secondary: const Icon(Icons.celebration_outlined),
                    title: const Text('Celebrations & haptics'),
                    subtitle: const Text(
                        'Win celebrations and vibration feedback on fills'),
                    value: ref.watch(feedbackEnabledProvider),
                    onChanged: (v) =>
                        ref.read(feedbackEnabledProvider.notifier).set(v),
                  ),
                ),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.new_releases_outlined),
                    title: const Text("What's new"),
                    subtitle: const Text('Recent updates and improvements'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/whats-new'),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Future<void> _tutorialSettings(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final current = ref.watch(tutorialProvider).skillLevel;
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('Coaching level',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('How much the app explains as you trade.',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                for (final level in SkillLevel.values)
                  ListTile(
                    title: Text(level.label),
                    subtitle: Text(level.blurb),
                    trailing: level == current
                        ? const Icon(Icons.check, color: AppTheme.up)
                        : null,
                    onTap: () => ref
                        .read(tutorialProvider.notifier)
                        .setSkillLevel(level),
                  ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.replay),
                  title: const Text('Replay the tutorial'),
                  subtitle:
                      const Text('Re-run the welcome and show every tip again.'),
                  onTap: () {
                    ref.read(tutorialProvider.notifier).reset();
                    Navigator.pop(context);
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _pickCurrency(BuildContext context, WidgetRef ref) async {
    final current = ref.read(currencyProvider);
    final selected = await showModalBottomSheet<Currency>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Display currency',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Just the display unit — your balances and the market are '
                'unchanged. The rate is taken from the in-game forex market when '
                'you pick, then held steady so values stay consistent.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            for (final currency in kCurrencies)
              ListTile(
                leading: SizedBox(
                  width: 32,
                  child: Text(currency.symbol,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                title: Text(currency.name),
                subtitle: Text(currency.pairSymbol == null
                    ? '${currency.code} · base currency'
                    : '${currency.code} · 1 USD ≈ ${currency.symbol}'
                        '${ref.read(currencyProvider.notifier).liveRateFor(currency).toStringAsFixed(currency.decimals == 0 ? 0 : 2)}'),
                trailing: currency.code == current.code
                    ? const Icon(Icons.check, color: AppTheme.up)
                    : null,
                onTap: () => Navigator.pop(context, currency),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      ref.read(currencyProvider.notifier).setCurrency(selected);
    }
  }

  Future<void> _editName(
      BuildContext context, WidgetRef ref, String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.trim() == current) return;
    try {
      await ref.read(profileRepositoryProvider).updateDisplayName(name);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }
}

/// The player's avatar with their equipped frame and a level badge.
class _LevelRingAvatar extends StatelessWidget {
  const _LevelRingAvatar({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    return TraderAvatar(
      name: profile.displayName,
      equipped: profile.equipped,
      radius: 28,
      level: profile.level,
    );
  }
}

class _TinyChip extends StatelessWidget {
  const _TinyChip(
      {required this.icon, required this.label, this.color = Colors.grey});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppTheme.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        margin: const EdgeInsets.all(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: color,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontSize: 8.5,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade500)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The earn-then-buy-in progression ladder, with affordability feedback.
class _ProgressionTile extends ConsumerWidget {
  const _ProgressionTile({
    required this.assetClass,
    required this.isUnlocked,
    required this.cash,
  });

  final AssetClass assetClass;
  final bool isUnlocked;
  final double cash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final affordable = cash >= assetClass.unlockCost;
    return Card(
      child: ListTile(
        leading: Icon(
          isUnlocked ? Icons.lock_open : Icons.lock_outline,
          color: isUnlocked ? AppTheme.up : null,
        ),
        title: Text(assetClass.name),
        subtitle: Text(isUnlocked
            ? assetClass.description
            : assetClass.isEnabled
                ? '${assetClass.description}\n'
                    '${affordable ? 'You can afford this!' : 'Progress: ${Fmt.money(cash)} of ${Fmt.money(assetClass.unlockCost)}'}'
                : 'Coming soon'),
        isThreeLine: !isUnlocked && assetClass.isEnabled,
        trailing: isUnlocked || !assetClass.isEnabled
            ? null
            : FilledButton.tonal(
                onPressed: affordable ? () => _unlock(context, ref) : null,
                child: Text(Fmt.moneyCompact(assetClass.unlockCost)),
              ),
      ),
    );
  }

  Future<void> _unlock(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final receipt = await ref
          .read(tradingRepositoryProvider)
          .purchaseAssetClassUnlock(assetClass.id);
      if (receipt.status == 'unlocked') {
        ref.invalidate(unlockedClassesProvider);
        messenger.showSnackBar(SnackBar(
            content: Text('${assetClass.name} unlocked! New assets are live '
                'on the Market tab.')));
      } else {
        messenger.showSnackBar(
            SnackBar(content: Text(receipt.reason ?? 'Unlock failed')));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}
