import 'package:jev_common/jev_common.dart';

import 'cell_maze.dart';

/// What the model is shown.
enum Observation {
  /// Only exits of visited cells, exactly like the original demo.
  partial,

  /// Every cell's exits, the graph analogue of showing the whole ASCII maze.
  full,
}

/// Port of `buildRequest` from pahndev/Type-Safe-Maze-Demo-/typesafe.js,
/// generalised to `n x n`, to [Observation.full], and to `k` questions.
///
/// Question `move` is theirs verbatim: a Choice over the legal exits of the
/// current cell, each described with row/column and prior visit count.
/// Questions `step2..stepk` are our lookahead add-on: the direction of each
/// later move, since legal cells for those are unknown until move 1 is
/// applied.
Map<String, Object?> buildGraphState(
  CellMaze m,
  List<int> history, {
  required Observation observation,
}) {
  final current = history.last;
  final n = m.n;
  int visits(int cell) => history.where((h) => h == cell).length;
  Map<String, Object?> cellInfo(int cell) {
    final (row, col) = m.rowCol(cell);
    return {
      'cell': cell,
      'row': row,
      'column': col,
      'visits': visits(cell),
      'exits': m.exits[cell],
    };
  }

  final revealed = observation == Observation.partial
      ? history.toSet().toList()
      : List.generate(m.cells, (i) => i);
  return {
    'description': observation == Observation.partial
        ? '$n×$n maze; row-major IDs 0–${m.goal}. Only exits of visited cells '
            'are revealed. All passages are bidirectional. Other walls are unknown.'
        : '$n×$n maze; row-major IDs 0–${m.goal}. Every cell is listed with '
            'its exits. All passages are bidirectional.',
    'current': current,
    'goal': m.goal,
    'history': history,
    'discovered': revealed.map(cellInfo).toList(),
  };
}

Map<String, Question> buildGraphQuestions(
  CellMaze m,
  List<int> history, {
  int k = 1,
}) {
  final current = history.last;
  int visits(int cell) => history.where((h) => h == cell).length;
  final move = Choice(
    'Choose the next legal move from the current cell toward goal ${m.goal}. '
    'Explore unknown passages when useful. Use history and visit counts to '
    'avoid repeating loops. Backtrack when needed. You only know the '
    'discovered portion of the maze.',
    {
      for (final next in m.exits[current])
        'to_$next': () {
          final (row, col) = m.rowCol(next);
          return 'Move to cell $next, row $row, column $col. '
              'Visited ${visits(next)} times.';
        }(),
    },
  );
  return {
    'move': move,
    for (var i = 2; i <= k; i++)
      'step$i': Choice(
        'Direction of move number $i, counting the move chosen in question '
        '"move" as move 1, continuing the same route toward goal ${m.goal}.',
        const {
          'N': 'row - 1',
          'E': 'column + 1',
          'S': 'row + 1',
          'W': 'column - 1',
        },
      ),
  };
}

int chosenCell(ChoiceAnswer a) => int.parse(a.choice.substring(3));

/// Directions for steps 2..k in order.
List<Dir4> laterDirections(Map<String, Answer> answers) {
  final ids = answers.keys.where((k) => k.startsWith('step')).toList()
    ..sort((a, b) => int.parse(a.substring(4)).compareTo(int.parse(b.substring(4))));
  return [for (final id in ids) Dir4.fromLabel((answers[id] as ChoiceAnswer).choice)];
}

/// Replays move 1 (a cell) then the predicted directions on the full maze.
/// `passablePrefix` counts leading moves through open passages that do not
/// revisit a cell of this replay; `optimalPrefix` counts leading moves that
/// stay on a shortest path to the goal.
class LookaheadEval {
  const LookaheadEval(this.passablePrefix, this.optimalPrefix, this.optimalMatch,
      this.reachedGoalAt);
  final int passablePrefix;
  final int optimalPrefix;

  /// Per step, whether the move keeps the shortest distance decreasing.
  final List<bool> optimalMatch;

  /// 1-based step at which the goal was reached, or null.
  final int? reachedGoalAt;

  String get bits => optimalMatch.map((b) => b ? '1' : '0').join();

  Map<String, Object?> toJson() => {
        'passablePrefix': passablePrefix,
        'optimalPrefix': optimalPrefix,
        'optimalMatch': bits,
        'reachedGoalAt': reachedGoalAt,
      };
}

LookaheadEval evaluateLookahead(CellMaze m, int from, int firstCell, List<Dir4> later) {
  var cell = from;
  final seen = {from};
  var passable = 0, optimal = 0;
  var passableRun = true, optimalRun = true;
  int? goalAt;
  final match = <bool>[];
  final moves = <int?>[firstCell, ...later.map((d) => null)];
  for (var i = 0; i < moves.length; i++) {
    final next = i == 0 ? firstCell : m.step(cell, later[i - 1]);
    final ok = next != null && m.exits[cell].contains(next) && !seen.contains(next);
    final closer = next != null && m.distances[next] == m.distances[cell] - 1;
    match.add(closer);
    if (ok && passableRun) {
      passable++;
    } else {
      passableRun = false;
    }
    if (closer && optimalRun) {
      optimal++;
    } else {
      optimalRun = false;
    }
    if (next == null) break;
    cell = next;
    seen.add(cell);
    if (cell == m.goal) {
      goalAt = i + 1;
      break;
    }
  }
  return LookaheadEval(passable, optimal, match, goalAt);
}
