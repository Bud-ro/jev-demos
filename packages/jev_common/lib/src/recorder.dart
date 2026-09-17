import 'dart:convert';
import 'dart:io';

/// Append-only newline-delimited JSON writer. Flushes on every write so a
/// crashed run still leaves usable data.
class JsonlWriter {
  JsonlWriter(this.file) {
    file.parent.createSync(recursive: true);
    _sink = file.openWrite(mode: FileMode.append);
  }

  final File file;
  late final IOSink _sink;
  int _count = 0;

  int get count => _count;

  Future<void> write(Map<String, Object?> record) async {
    _sink.writeln(jsonEncode(record));
    _count++;
    await _sink.flush();
  }

  Future<void> close() => _sink.close();
}

/// Reads a JSONL file into a list of maps.
List<Map<String, dynamic>> readJsonl(File file) {
  if (!file.existsSync()) return const [];
  return file
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => jsonDecode(l) as Map<String, dynamic>)
      .toList();
}

/// A timestamped output directory for one demo run, e.g.
/// `results/20260916-213000-quick/`.
class RunDir {
  RunDir(this.dir);

  factory RunDir.create(String base, String label) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final dir = Directory('$base${Platform.pathSeparator}$stamp-$label')
      ..createSync(recursive: true);
    return RunDir(dir);
  }

  final Directory dir;
  final Map<String, JsonlWriter> _writers = {};

  String get path => dir.path;

  File file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  JsonlWriter jsonl(String name) =>
      _writers.putIfAbsent(name, () => JsonlWriter(file(name)));

  Future<void> writeJson(String name, Object? value) =>
      file(name).writeAsString(const JsonEncoder.withIndent('  ').convert(value));

  Future<void> close() async {
    for (final w in _writers.values) {
      await w.close();
    }
    _writers.clear();
  }
}
