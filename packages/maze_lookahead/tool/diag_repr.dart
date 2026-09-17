// Diagnostic: does the way the maze is serialized change Jev's answers?
//
// Sends one maze in several representations and prints predicted moves vs
// the optimal path. A handful of sequential calls; run from the repo root:
//   dart run maze_lookahead:diag_repr
import 'dart:convert';

import 'package:jev_common/jev_common.dart';
import 'package:maze_lookahead/maze_lookahead.dart';

Future<void> main() async {
  final client = JevClient.fromEnv(loadEnv());
  const k = 25;

  Future<void> probe(String label, Maze maze, Object state,
      {Phrasing phrasing = Phrasing.bare}) async {
    final res = await client.systemOne(
        state: state, questions: stepQuestions(phrasing, k));
    final moves = answersToMoves(res.answers);
    final eval = evaluateSequence(maze, moves);
    final s1 = res.choice(stepId(1));
    String short(Iterable<Dir> ds) => ds.map((d) => d.label[0]).join(' ');
    print('--- $label  (${res.usage.inputTokens} tok, ${res.latency.inMilliseconds}ms)');
    print('optimal : ${short(maze.optimalMoves().take(k))}');
    print('predict : ${short(moves)}');
    print('valid=${eval.validPrefix} optimal=${eval.optimalPrefix} '
        'step1=${s1.choice} probs=${s1.probabilities.map((k, v) => MapEntry(k, v.toStringAsFixed(2)))}');
  }

  // 1. Representation test on the maze the sweep used first.
  final maze = Maze.generate(5, seed: 1 + 5 * 1000, algo: 'prim');
  final walker = Walker(maze);
  final base = buildState(maze, walker);
  print(maze.renderString(at: walker.pos));
  print('');

  await probe('A: current (JSON object, maze as one string with \\n)', maze, base);

  final rows = {...base, 'maze': maze.render(at: walker.pos)};
  await probe('B: JSON object, maze as array of row strings', maze, rows);

  final text = StringBuffer()
    ..writeln(base['task'])
    ..writeln()
    ..writeln('Rules:');
  for (final e in (base['grid_rules'] as Map).entries) {
    text.writeln('- ${e.key}: ${e.value}');
  }
  text.writeln();
  text.writeln('Legend: # wall, space open floor, @ you, G goal, . visited');
  text.writeln(base['questions']);
  text.writeln();
  text.writeln('You are at row ${walker.pos.r}, col ${walker.pos.c}. '
      'The goal is at row ${maze.goal.r}, col ${maze.goal.c}.');
  text.writeln();
  text.writeln('Maze:');
  text.writeln(maze.renderString(at: walker.pos));
  await probe('C: plain-text state with real newlines', maze, text.toString());

  final rowsWithIndex = {
    ...base,
    'maze': [
      for (var r = 0; r < maze.width; r++)
        '${r.toString().padLeft(2)} ${maze.render(at: walker.pos)[r]}'
    ],
  };
  await probe('D: array of rows, each prefixed with its row number', maze, rowsWithIndex);

  // 2. Wall-reading test: a start where RIGHT is a wall and DOWN is open.
  Maze? wallMaze;
  for (var seed = 1; seed < 500; seed++) {
    final m = Maze.generate(5, seed: seed, algo: 'prim');
    if (m.isWall((r: 1, c: 2)) && m.isOpen((r: 2, c: 1))) {
      wallMaze = m;
      break;
    }
  }
  if (wallMaze != null) {
    print('');
    print('Wall test: RIGHT from the start is a wall (seed ${wallMaze.seed})');
    print(wallMaze.renderString(at: wallMaze.start));
    final w = Walker(wallMaze);
    await probe('E: JSON object (current)', wallMaze, buildState(wallMaze, w));
    await probe('F: JSON object, maze as array of rows', wallMaze,
        {...buildState(wallMaze, w), 'maze': wallMaze.render(at: w.pos)});
  }

  // 3. Is the goal position driving it? Same maze A, but described criteria.
  await probe('G: as A but with described criteria', maze, base,
      phrasing: Phrasing.described);

  client.close();
  print('');
  print('(${jsonEncode(base).length} JSON chars for the base state)');
}
