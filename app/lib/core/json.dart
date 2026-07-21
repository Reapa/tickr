/// Defensive JSON coercion. PostgREST serializes Postgres `numeric` as JSON
/// numbers, but strings can appear depending on settings — accept both.
double jsonDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

int jsonInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

DateTime jsonDate(Object? value) {
  if (value is String) return DateTime.parse(value).toLocal();
  return DateTime.fromMillisecondsSinceEpoch(0);
}
