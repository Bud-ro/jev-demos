import 'dart:convert';

import 'package:jev_common/jev_common.dart';
import 'package:maze_lookahead/maze_lookahead.dart';
import 'package:test/test.dart';

void main() {
  group('Maze', () {
    for (final algo in ['prim', 'dfs']) {
      test('$algo generates a perfect maze that is solvable and deterministic', () {
        final a = Maze.generate(10, seed: 7, algo: algo);
        final b = Maze.generate(10, seed: 7, algo: algo);
        expect(a.render(), b.render());
        expect(a.width, 21);
        expect(a.solutionLength, greaterThan(0));
        // Every cell is reachable (perfect maze = spanning tree).
        for (var r = 1; r < a.width; r += 2) {
          for (var c = 1; c < a.width; c += 2) {
            expect(a.distanceFrom((r: r, c: c)), greaterThanOrEqualTo(0));
          }
        }
        // Optimal moves actually lead to the goal without touching walls.
        final w = Walker(a);
        for (final m in a.optimalMoves()) {
          final res = w.apply(m);
          expect(res.error, isNull, reason: 'move $m at ${res.before}');
        }
        expect(w.atGoal, isTrue);
        expect(w.steps, a.solutionLength + 1);
      });
    }

    test('render shows @, G, and trail; parse round-trips', () {
      final m = Maze.generate(5, seed: 1);
      final lines = m.render(at: (r: 1, c: 3), trail: {(r: 1, c: 2)});
      expect(lines[1][3], '@');
      expect(lines[1][2], '.');
      expect(lines[m.width - 2][m.width - 2], 'G');
      final parsed = Maze.parse(lines);
      expect(parsed.start, (r: 1, c: 3));
      expect(parsed.goal, m.goal);
      expect(parsed.distanceFrom(parsed.start), m.distanceFrom((r: 1, c: 3)));
    });
  });

  group('Walker error rules', () {
    late Maze m;
    setUp(() => m = Maze.generate(5, seed: 1));

    test('wall bump keeps position', () {
      final w = Walker(m);
      final r = w.apply(Dir.up); // row 0 is the border wall
      expect(r.error, MoveError.wall);
      expect(r.after, m.start);
    });

    test('backtrack onto a visited cell', () {
      final w = Walker(m);
      final first = m.optimalMoves().first;
      expect(w.apply(first).error, isNull);
      expect(w.apply(first.opposite).error, MoveError.backtrack);
    });

    test('NONE before the goal is premature; NONE on the goal is fine', () {
      final w = Walker(m);
      expect(w.apply(Dir.none).error, MoveError.prematureNone);
      final done = Walker(m, start: m.goal);
      expect(done.apply(Dir.none).error, isNull);
      expect(done.apply(Dir.up).error, MoveError.offGoal);
    });
  });

  group('evaluateSequence', () {
    test('counts valid and optimal prefixes and stops at NONE', () {
      final m = Maze.generate(5, seed: 1);
      final optimal = m.optimalMoves();
      // Perfect prediction.
      final perfect = evaluateSequence(m, [...optimal, Dir.up, Dir.up]);
      expect(perfect.completed, isTrue);
      expect(perfect.truncatedAtNone, isTrue);
      expect(perfect.steps.length, optimal.length);
      expect(perfect.validPrefix, optimal.length);
      expect(perfect.optimalPrefix, optimal.length);
      expect(perfect.optimalMatch.every((b) => b), isTrue);

      // Second move reverses the first: always a backtrack. The rest is
      // still replayed (for GIFs) but no longer counts toward the prefixes.
      final bad = [...optimal];
      bad[1] = bad[0].opposite;
      final e = evaluateSequence(m, bad);
      expect(e.validPrefix, 1);
      expect(e.optimalPrefix, 1);
      expect(e.firstError, MoveError.backtrack);
      expect(e.completed, isFalse);
      expect(e.optimalMatch[1], isFalse);
      expect(e.steps.length, bad.length); // replays through the final NONE
    });
  });

  group('prompt', () {
    test('questions parse back to step numbers and moves', () {
      final qs = stepQuestions(Phrasing.bare, 3);
      expect(qs.keys, ['s1', 's2', 's3']);
      expect((qs['s2'] as Choice).instructions, '2');
      expect(stepFromId('s42'), 42);
      final moves = answersToMoves({
        's2': const ChoiceAnswer('LEFT', {}, 0.5),
        's1': const ChoiceAnswer('UP', {}, 0.5),
        's3': const ChoiceAnswer('NONE', {}, 0.5),
      });
      expect(moves, [Dir.up, Dir.left, Dir.none]);
    });

    test('state carries the maze, position and goal', () {
      final m = Maze.generate(5, seed: 1);
      final state = buildState(m, Walker(m));
      expect(state['position'], {'row': 1, 'col': 1});
      expect(state['goal'], {'row': m.goal.r, 'col': m.goal.c});
      expect((state['maze'] as String).split('\n').length, m.width);
      expect(jsonEncode(state), contains('@'));
    });
  });

  group('MockJev', () {
    test('a perfect oracle solves any maze through the real client', () async {
      final oracle = MockJev(accuracy: 1.0, decay: 1.0);
      final client = JevClient(apiKey: 'x', httpClient: oracle.client());
      final m = Maze.generate(8, seed: 3);
      final res = await client.systemOne(
        state: buildState(m, Walker(m)),
        questions: stepQuestions(Phrasing.step, 60),
      );
      final eval = evaluateSequence(m, answersToMoves(res.answers));
      expect(eval.completed, isTrue);
      expect(eval.optimalPrefix, m.solutionLength + 1);
      expect(res.usage.inputTokens, greaterThan(0));
    });

    test('rejects oversized state with 422', () async {
      final oracle = MockJev(maxInputTokens: 100);
      final client = JevClient(apiKey: 'x', httpClient: oracle.client());
      final m = Maze.generate(20, seed: 3);
      expect(
        () => client.systemOne(
          state: buildState(m, Walker(m)),
          questions: stepQuestions(Phrasing.bare, 5),
        ),
        throwsA(isA<JevApiException>().having((e) => e.status, 'status', 422)),
      );
    });
  });
}
