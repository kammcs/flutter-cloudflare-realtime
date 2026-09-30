// Internal JSON helpers for the broker models. Not exported.
//
// Every error message names the offending field only, never its value:
// values can be SDP, tokens or credentials.

/// Casts [value] to a JSON object, or throws a [FormatException] naming
/// [what].
Map<String, Object?> jsonObject(Object? value, String what) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw FormatException('Expected a JSON object for "$what".');
}

/// Reads an optional string field.
String? optString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('Expected a string for "$key".');
}

/// Reads a required string field.
String reqString(Map<String, Object?> json, String key) {
  final value = optString(json, key);
  if (value == null) throw FormatException('Missing required field "$key".');
  return value;
}

/// Reads an optional boolean field.
bool? optBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is bool) return value as bool?;
  throw FormatException('Expected a boolean for "$key".');
}

/// Reads an optional integer field. Accepts integral JSON numbers such as
/// `3.0`, since the schema types some IDs as `number`.
int? optInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value == value.truncate()) return value.toInt();
  throw FormatException('Expected an integer for "$key".');
}

/// Reads an optional nested object field and converts it with [fromJson].
T? optObject<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?> json) fromJson,
) {
  final value = json[key];
  if (value == null) return null;
  return fromJson(jsonObject(value, key));
}

/// Reads an optional array of objects. A missing field gives an empty list.
List<T> optList<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?> json) fromJson,
) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List) throw FormatException('Expected an array for "$key".');
  return List<T>.unmodifiable(value.map((e) => fromJson(jsonObject(e, key))));
}

/// Finds the enum value whose [Enum.name] equals the string in [key], or
/// returns null when the field is absent or holds an unknown value.
T? optEnum<T extends Enum>(
  Map<String, Object?> json,
  String key,
  List<T> values,
) {
  final name = optString(json, key);
  if (name == null) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

/// Adds `key: value` to [json] when [value] is not null.
void putIfNotNull(Map<String, Object?> json, String key, Object? value) {
  if (value != null) json[key] = value;
}
