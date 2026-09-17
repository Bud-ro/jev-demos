import 'dart:io';

/// Loads a `.env` file (searching from [from] upward to the filesystem root)
/// and merges it under the real process environment. Process env wins.
///
/// Supports `KEY=value`, `export KEY=value`, `#` comments, and single or
/// double quoted values. No interpolation.
Map<String, String> loadEnv({Directory? from}) {
  final merged = <String, String>{};
  final file = _findDotEnv(from ?? Directory.current);
  if (file != null) {
    for (var line in file.readAsLinesSync()) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('export ')) line = line.substring(7).trim();
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final key = line.substring(0, eq).trim();
      var value = line.substring(eq + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      } else {
        final hash = value.indexOf(' #');
        if (hash >= 0) value = value.substring(0, hash).trim();
      }
      merged[key] = value;
    }
  }
  merged.addAll(Platform.environment);
  return merged;
}

File? _findDotEnv(Directory start) {
  var dir = start.absolute;
  while (true) {
    final candidate = File('${dir.path}${Platform.pathSeparator}.env');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

/// Returns the value of [key] from [env] (defaults to [loadEnv]) or throws a
/// [StateError] with a helpful message.
String requireEnv(String key, {Map<String, String>? env}) {
  final value = (env ?? loadEnv())[key];
  if (value == null || value.isEmpty) {
    throw StateError(
      'Missing $key. Copy .env.example to .env at the repo root and set it, '
      'or export it in your shell.',
    );
  }
  return value;
}
