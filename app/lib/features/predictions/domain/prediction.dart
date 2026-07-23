import '../../../core/json.dart';

/// A binary "will it close higher?" micro-bet posted by the game.
class Prediction {
  const Prediction({
    required this.id,
    required this.assetId,
    required this.question,
    required this.closesAt,
    required this.openPrice,
    required this.rewardXp,
    required this.status,
    this.result,
    this.closePrice,
  });

  factory Prediction.fromJson(Map<String, dynamic> json) => Prediction(
        id: json['id'] as String,
        assetId: json['asset_id'] as String,
        question: json['question'] as String,
        closesAt: jsonDate(json['closes_at']),
        openPrice: jsonDouble(json['open_price']),
        rewardXp: jsonInt(json['reward_xp']),
        status: json['status'] as String,
        result: json['result'] as String?,
        closePrice: json['close_price'] == null
            ? null
            : jsonDouble(json['close_price']),
      );

  final String id;
  final String assetId;
  final String question;
  final DateTime closesAt;
  final double openPrice;
  final int rewardXp;
  final String status; // open | resolved
  final String? result; // up | down | flat
  final double? closePrice;

  Duration get countdown {
    final left = closesAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }
}

/// An open prediction paired with the player's own call (if any).
class OpenPrediction {
  const OpenPrediction({required this.prediction, this.myChoice});

  final Prediction prediction;
  final String? myChoice; // up | down | null

  bool get answered => myChoice != null;
}

/// The result of one of the player's calls once it resolves.
class PredictionResult {
  const PredictionResult({required this.correct, required this.awardedXp});

  final bool correct;
  final int awardedXp;
}
