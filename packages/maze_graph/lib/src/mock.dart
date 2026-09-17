import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Offline oracle for the graph demo. Answers `move` with a random legal
/// option (preferring unvisited exits with probability [accuracy]) and the
/// lookahead steps with random directions, so the pipeline can be exercised
/// without a key. It cannot see the full maze, so it is not a solver.
class MockGraphJev {
  MockGraphJev({this.accuracy = 0.8, int seed = 42, this.maxInputTokens = 32000})
      : _rng = math.Random(seed);
  final double accuracy;
  final int maxInputTokens;
  final math.Random _rng;
  int calls = 0;

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    calls++;
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final tokens = (req.body.length / 3.2).round();
    if (tokens > maxInputTokens) {
      return http.Response(jsonEncode({'detail': 'token budget exceeded ($tokens)'}), 422);
    }
    final questions = body['questions'] as Map<String, dynamic>;
    final answers = <String, Object?>{};
    for (final e in questions.entries) {
      final q = e.value as Map<String, dynamic>;
      final criteria = q['criteria'] as Map<String, dynamic>;
      final options = criteria.keys.toList();
      String chosen;
      if (e.key == 'move' && _rng.nextDouble() < accuracy) {
        final fresh = options.where((o) => '${criteria[o]}'.contains('Visited 0 times')).toList();
        chosen = (fresh.isEmpty ? options : fresh)[_rng.nextInt(fresh.isEmpty ? options.length : fresh.length)];
      } else {
        chosen = options[_rng.nextInt(options.length)];
      }
      final peak = 0.5 + _rng.nextDouble() * 0.45;
      final rest = options.length == 1 ? 0.0 : (1 - peak) / (options.length - 1);
      answers[e.key] = {
        'type': 'choice',
        'choice': chosen,
        'probabilities': {for (final o in options) o: options.length == 1 ? 1.0 : (o == chosen ? peak : rest)},
        'confidence': options.length == 1 ? 1.0 : peak,
      };
    }
    return http.Response(
      jsonEncode({
        'model': 'mock-jev',
        'answers': answers,
        'usage': {'input_tokens': tokens, 'output_tokens': questions.length * 2},
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}
