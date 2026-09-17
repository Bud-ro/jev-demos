import 'package:jev_common/jev_common.dart';
import 'package:maze_graph/maze_graph.dart';
import 'package:test/test.dart';

void main() {
  test('generated mazes are connected, two-way, deterministic, and BFS-consistent', () {
    for (var seed = 1; seed <= 200; seed++) {
      final m = CellMaze.generate(5, seed: seed);
      expect(CellMaze.generate(5, seed: seed).exits, m.exits);
      for (var c = 0; c < m.cells; c++) {
        expect(m.distance(c), greaterThanOrEqualTo(0), reason: 'cell $c unreachable');
        for (final x in m.exits[c]) {
          expect(m.exits[x], contains(c));
          expect(CellMaze.adjacent(c, 5), contains(x));
        }
      }
      final path = m.optimalPath();
      expect(path.first, 0);
      expect(path.last, 24);
      expect(path.length - 1, m.optimalMoves);
      for (var i = 1; i < path.length; i++) {
        expect(m.exits[path[i - 1]], contains(path[i]));
      }
    }
  });

  test('perfect maze (extra 0) has exactly cells-1 passages', () {
    final m = CellMaze.generate(10, seed: 3, extra: 0);
    final passages = m.exits.fold<int>(0, (a, e) => a + e.length) ~/ 2;
    expect(passages, m.cells - 1);
  });

  test('state mirrors the original request shape', () {
    final m = CellMaze.generate(5, seed: 1);
    final first = m.exits[0].first;
    final history = [0, first, 0];
    final state = buildGraphState(m, history, observation: Observation.partial);
    expect(state['current'], 0);
    expect(state['goal'], 24);
    expect(state['history'], history);
    final discovered = (state['discovered'] as List).cast<Map<String, Object?>>();
    expect(discovered.map((d) => d['cell']), [0, first]);
    expect(discovered.first['visits'], 2);
    expect(discovered.first['row'], 1);
    expect(state.containsKey('passages'), isFalse);
    final q = buildGraphQuestions(m, history, k: 3);
    expect((q['move'] as Choice).criteria.keys, m.exits[0].map((n) => 'to_$n'));
    expect((q['move'] as Choice).criteria['to_$first'], contains('Visited 1 times'));
    expect(q.keys, ['move', 'step2', 'step3']);
    final full = buildGraphState(m, history, observation: Observation.full);
    expect((full['discovered'] as List).length, 25);
  });

  test('lookahead evaluation counts optimal and passable prefixes', () {
    final m = CellMaze.generate(6, seed: 9, extra: 0);
    final dirs = m.optimalDirections();
    final first = m.step(0, dirs.first)!;
    final e = evaluateLookahead(m, 0, first, dirs.skip(1).toList());
    expect(e.optimalPrefix, dirs.length);
    expect(e.reachedGoalAt, dirs.length);
    final wrong = [Dir4.n, Dir4.n]; // off the top edge: wall
    final e2 = evaluateLookahead(m, 0, first, wrong);
    expect(e2.optimalPrefix, 1);
    expect(e2.passablePrefix, 1);
  });

  test('baselines run and the unvisited policy beats random', () {
    final m = CellMaze.generate(5, seed: 5);
    final r = simulateBaseline(m, policy: 'random', cap: 80, runs: 500);
    final u = simulateBaseline(m, policy: 'unvisited', cap: 80, runs: 500);
    expect(u.solveRate, greaterThanOrEqualTo(r.solveRate));
  });

  test('mock oracle answers only legal options through the real client', () async {
    final client = JevClient(apiKey: 'x', httpClient: MockGraphJev().client());
    final m = CellMaze.generate(5, seed: 2);
    final res = await client.systemOne(
      state: buildGraphState(m, [0], observation: Observation.partial),
      questions: buildGraphQuestions(m, [0], k: 4),
    );
    expect(m.exits[0], contains(chosenCell(res.choice('move'))));
    expect(laterDirections(res.answers).length, 3);
  });
}
