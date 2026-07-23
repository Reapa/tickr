import '../../../core/json.dart';

/// A property the player owns outright. Earns rent into the Collect loop; its
/// value builds total net worth on the tycoon track (excluded from seasons).
/// Phase 3b adds growth decisions and maintenance events (condition/insured).
class Property {
  const Property({
    required this.id,
    required this.name,
    required this.typeId,
    required this.value,
    required this.rentRate,
    required this.investedBasis,
    required this.condition,
    required this.insured,
    required this.status,
  });

  factory Property.fromJson(Map<String, dynamic> json) => Property(
        id: json['id'] as String,
        name: json['name'] as String,
        typeId: json['type_id'] as String,
        value: jsonDouble(json['value']),
        rentRate: jsonDouble(json['rent_rate']),
        investedBasis: jsonDouble(json['invested_basis']),
        condition: jsonDouble(json['condition'], 100),
        insured: (json['insured'] as bool?) ?? false,
        status: (json['status'] as String?) ?? 'owned',
      );

  final String id;
  final String name;
  final String typeId;
  final double value;

  /// Rent per game-year (14 real days) at full condition.
  final double rentRate;
  final double investedBasis;
  final double condition; // 0-100; damaged property earns less
  final bool insured;
  final String status;

  /// Effective rent after condition.
  double get effectiveRent => rentRate * condition / 100;
  double get valueGain => value - investedBasis;
}

class PropertyType {
  const PropertyType({
    required this.id,
    required this.name,
    required this.description,
    required this.minPrice,
    required this.rentYield,
  });

  factory PropertyType.fromJson(Map<String, dynamic> json) => PropertyType(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String,
        minPrice: jsonDouble(json['min_price']),
        rentYield: jsonDouble(json['rent_yield']),
      );

  final String id;
  final String name;
  final String description;
  final double minPrice;
  final double rentYield;
}

class PropertyListing {
  const PropertyListing({
    required this.id,
    required this.name,
    required this.typeId,
    required this.value,
    required this.rentRate,
  });

  factory PropertyListing.fromJson(Map<String, dynamic> json) => PropertyListing(
        id: json['id'] as String,
        name: json['name'] as String,
        typeId: json['type_id'] as String,
        value: jsonDouble(json['value']),
        rentRate: jsonDouble(json['rent_rate']),
      );

  final String id;
  final String name;
  final String typeId;
  final double value;
  final double rentRate;
}
