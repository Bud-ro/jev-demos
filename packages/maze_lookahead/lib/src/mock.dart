import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'maze.dart';

/// An offline stand-in for the Jev API so the whole pipeline (recording,
/// analysis, GIF data) can be exercised without a key or network.
///
/// It reads the maze out of the request state, solves it, and answers step
/// `n` with the optimal move with probability `accuracy * decay^(n-1)`,
/// otherwise a random wrong move. Beyond the goal it answers NONE.
class MockJev {
  MockJev({
    this.accuracy = 0.95,
    this.decay = 0.97,
    this.latency = Duration.zero,
    this.maxInputTokens = 32000,
    this.charsPerToken = 2.5,
    int seed = 42,
  }) : _rng = math.Random(seed);

  final double accuracy;
  final double decay;
  final Duration latency;
  final int maxInputTokens;
  final double charsPerToken;
  final math.Random _rng;

  int calls = 0;

  http.Client client() => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    calls++;
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (req.headers['Authorization']?.startsWith('Bearer ') != true) {
      return http.Response('{"detail":"missing bearer token"}', 401);
    }
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final inputTokens = (req.body.length / charsPerToken).round();
    if (inputTokens > maxInputTokens) {
      return http.Response(
        jsonEncode({
          'detail': 'request exceeds the token budget '
              '($inputTokens > $maxInputTokens input tokens)',
        }),
        422,
      );
    }

    final state = body['state'] as Map<String, dynamic>;
    final lines = (state['maze'] as String).split('\n');
    final pos = state['position'] as Map<String, dynamic>;
    final goal = state['goal'] as Map<String, dynamic>;
    final maze = Maze.parse(
      lines,
      at: (r: pos['row'] as int, c: pos['col'] as int),
      goalAt: (r: goal['row'] as int, c: goal['col'] as int),
    );
    final optimal = maze.optimalMoves(from: maze.start);

    final questions = body['questions'] as Map<String, dynamic>;
    final answers = <String, Object?>{};
    for (final entry in questions.entries) {
      final q = entry.value as Map<String, dynamic>;
      final options = (q['criteria'] as Map<String, dynamic>).keys.toList();
      final n = _stepNumber(q['instructions']);
      final wanted = n <= optimal.length ? optimal[n - 1] : Dir.none;
      final pCorrect = accuracy * math.pow(decay, n - 1);
      Dir chosen;
      if (_rng.nextDouble() < pCorrect) {
        chosen = wanted;
      } else {
        final wrong = Dir.values.where((d) => d != wanted).toList();
        chosen = wrong[_rng.nextInt(wrong.length)];
      }
      final peak = 0.55 + _rng.nextDouble() * 0.4;
      final rest = (1 - peak) / (options.length - 1);
      final probs = {
        for (final o in options) o: o == chosen.label ? peak : rest,
      };
      answers[entry.key] = {
        'type': 'choice',
        'choice': chosen.label,
        'probabilities': probs,
        'confidence': peak,
      };
    }
    return http.Response(
      jsonEncode({
        'model': 'mock-jev',
        'answers': answers,
        'usage': {'input_tokens': inputTokens, 'output_tokens': questions.length * 2},
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  static int _stepNumber(Object? instructions) {
    final text = instructions is String ? instructions : jsonEncode(instructions);
    final m = RegExp(r'\d+').firstMatch(text);
    if (m == null) throw FormatException('No step number in "$text"');
    return int.parse(m.group(0)!);
  }
}
