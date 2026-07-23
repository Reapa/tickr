import '../../../core/json.dart';

/// A business the player owns — founded from scratch or acquired. Its value
/// feeds total net worth (not seasons); its revenue accrues into the Collect
/// loop. Management decisions (Phase 2) and IPO (Phase 4) build on this.
class Company {
  const Company({
    required this.id,
    required this.name,
    required this.industryId,
    required this.origin,
    required this.level,
    required this.revenueRate,
    required this.valuation,
    required this.investedBasis,
    required this.status,
    required this.foundedAt,
  });

  factory Company.fromJson(Map<String, dynamic> json) => Company(
        id: json['id'] as String,
        name: json['name'] as String,
        industryId: json['industry_id'] as String,
        origin: (json['origin'] as String?) ?? 'founded',
        level: jsonInt(json['level'], 1),
        revenueRate: jsonDouble(json['revenue_rate']),
        valuation: jsonDouble(json['valuation']),
        investedBasis: jsonDouble(json['invested_basis']),
        status: (json['status'] as String?) ?? 'private',
        foundedAt: DateTime.parse(json['founded_at'] as String),
      );

  final String id;
  final String name;
  final String industryId;
  final String origin; // 'founded' | 'acquired'
  final int level;

  /// Cash earned per game-year (14 real days). Grows via decisions (Phase 2).
  final double revenueRate;
  final double valuation;
  final double investedBasis;
  final String status; // 'private' | 'public' | 'sold'
  final DateTime foundedAt;

  bool get isFounded => origin == 'founded';
  bool get isPublic => status == 'public';

  /// Unrealised value vs. what was put in.
  double get valueGain => valuation - investedBasis;
}

/// An industry you can found a company in.
class CompanyIndustry {
  const CompanyIndustry({
    required this.id,
    required this.name,
    required this.description,
    required this.minCapital,
    required this.revenueMultiple,
  });

  factory CompanyIndustry.fromJson(Map<String, dynamic> json) =>
      CompanyIndustry(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String,
        minCapital: jsonDouble(json['min_capital']),
        revenueMultiple: jsonDouble(json['revenue_multiple']),
      );

  final String id;
  final String name;
  final String description;
  final double minCapital;
  final double revenueMultiple;

  /// Annual revenue a fresh company of [capital] would start on.
  double startingRevenue(double capital) => capital / revenueMultiple;
}

/// A pending strategic decision for a company — reinvest choices or a reactive
/// event. The player picks an option; the server rolls a bounded outcome.
class CompanyDecision {
  const CompanyDecision({
    required this.id,
    required this.companyId,
    required this.kind,
    required this.prompt,
    required this.options,
    required this.expiresAt,
  });

  factory CompanyDecision.fromJson(Map<String, dynamic> json) => CompanyDecision(
        id: json['id'] as String,
        companyId: json['company_id'] as String,
        kind: (json['kind'] as String?) ?? 'reinvest',
        prompt: json['prompt'] as String,
        options: [
          for (final o in (json['options'] as List<dynamic>? ?? const []))
            DecisionOption.fromJson(o as Map<String, dynamic>),
        ],
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );

  final String id;
  final String companyId;
  final String kind; // 'reinvest' | 'event'
  final String prompt;
  final List<DecisionOption> options;
  final DateTime expiresAt;

  bool get isEvent => kind == 'event';
}

class DecisionOption {
  const DecisionOption({
    required this.key,
    required this.label,
    required this.blurb,
    required this.cost,
  });

  factory DecisionOption.fromJson(Map<String, dynamic> json) => DecisionOption(
        key: json['key'] as String,
        label: json['label'] as String,
        blurb: (json['blurb'] as String?) ?? '',
        cost: jsonDouble(json['cost']),
      );

  final String key;
  final String label;
  final String blurb;
  final double cost;
}

/// An established company available to acquire.
class CompanyListing {
  const CompanyListing({
    required this.id,
    required this.name,
    required this.industryId,
    required this.valuation,
    required this.revenueRate,
    required this.level,
  });

  factory CompanyListing.fromJson(Map<String, dynamic> json) => CompanyListing(
        id: json['id'] as String,
        name: json['name'] as String,
        industryId: json['industry_id'] as String,
        valuation: jsonDouble(json['valuation']),
        revenueRate: jsonDouble(json['revenue_rate']),
        level: jsonInt(json['level'], 1),
      );

  final String id;
  final String name;
  final String industryId;
  final double valuation;
  final double revenueRate;
  final int level;
}
