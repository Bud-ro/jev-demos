import 'maze.dart';

/// Why a move counted as an error, per the demo's rules:
/// - `wall`: moved into a wall or off the grid (position unchanged).
/// - `backtrack`: moved onto a position already visited in this trajectory.
/// - `offGoal`: moved after already standing on the goal.
/// - `prematureNone`: answered NONE before reaching the goal.
enum MoveError { wall, backtrack, offGoal, prematureNone }

class StepResult {
  const StepResult({
    required this.index,
    required this.move,
    required this.before,
    required this.after,
    required this.error,
    required this.atGoal,
    required this.distToGoal,
  });

  /// 1-based step index.
  final int index;
  final Dir move;
  final Pos before;
  final Pos after;
  final MoveError? error;

  /// Whether [after] is the goal.
  final bool atGoal;

  /// Shortest-path distance from [after] to the goal.
  final int distToGoal;

  bool get ok => error == null;

  Map<String, Object?> toJson() => {
        'i': index,
        'move': move.label,
        'before': [before.r, before.c],
        'after': [after.r, after.c],
        'error': error?.name,
        'atGoal': atGoal,
        'dist': distToGoal,
      };
}

/// Applies moves to a maze position while tracking visited cells and errors.
class Walker {
  Walker(this.maze, {Pos? start, Set<Pos>? visited})
      : pos = start ?? maze.start,
        visited = {...?visited, start ?? maze.start};

  final Maze maze;
  Pos pos;
  final Set<Pos> visited;
  int steps = 0;

  bool get atGoal => pos == maze.goal;
  int get distToGoal => maze.distanceFrom(pos);

  /// A copy with the same position and visited set.
  Walker clone() => Walker(maze, start: pos, visited: visited);

  StepResult apply(Dir move) {
    steps++;
    final before = pos;
    MoveError? error;
    var after = before;

    if (move == Dir.none) {
      if (!atGoal) error = MoveError.prematureNone;
    } else {
      final target = move.apply(before);
      if (atGoal) {
        error = MoveError.offGoal;
        if (maze.isOpen(target)) after = target;
      } else if (maze.isWall(target)) {
        error = MoveError.wall;
      } else if (visited.contains(target)) {
        error = MoveError.backtrack;
        after = target;
      } else {
        after = target;
      }
    }

    pos = after;
    visited.add(after);
    return StepResult(
      index: steps,
      move: move,
      before: before,
      after: after,
      error: error,
      atGoal: after == maze.goal,
      distToGoal: maze.distanceFrom(after),
    );
  }
}

/// Result of replaying a predicted move sequence from one position
/// ("follow ALL steps" mode).
class SequenceEval {
  const SequenceEval({
    required this.steps,
    required this.validPrefix,
    required this.optimalPrefix,
    required this.firstError,
    required this.completed,
    required this.truncatedAtNone,
    required this.optimalRemaining,
    required this.optimalMatch,
  });

  /// Replayed steps, cut off after the first NONE (inclusive).
  final List<StepResult> steps;

  /// Leading moves with no error. A NONE on the goal counts as a valid step.
  final int validPrefix;

  /// Leading moves that match the unique optimal path (NONE at goal included).
  final int optimalPrefix;

  final MoveError? firstError;

  /// The sequence reached the goal and then said NONE.
  final bool completed;

  /// Whether replay stopped because of a NONE answer.
  final bool truncatedAtNone;

  /// Optimal moves remaining from the start position (excluding NONE).
  final int optimalRemaining;

  /// Per step: whether the predicted move equals the optimal move at that
  /// depth, judged independently of earlier steps. Covers every replayed step.
  final List<bool> optimalMatch;

  /// `optimalMatch` as a compact `1`/`0` string for logs.
  String get optimalMatchBits => optimalMatch.map((b) => b ? '1' : '0').join();

  /// Per replayed step, `1` if it had no error else `0`.
  String get validBits => steps.map((s) => s.ok ? '1' : '0').join();

  Map<String, Object?> toJson() => {
        'validPrefix': validPrefix,
        'optimalPrefix': optimalPrefix,
        'firstError': firstError?.name,
        'completed': completed,
        'truncatedAtNone': truncatedAtNone,
        'optimalRemaining': optimalRemaining,
        'optimalMatch': optimalMatchBits,
        'valid': validBits,
        'steps': steps.map((s) => s.toJson()).toList(),
      };
}

/// Replays [moves] from [from] (with [visited] already seen), stopping after
/// the first NONE. Steps after an error are still simulated so a GIF can show
/// the whole predicted sequence. With [stopAtGoal] (for question sets that
/// have no NONE option) the replay ends, and counts as completed, as soon as
/// the goal is reached.
SequenceEval evaluateSequence(
  Maze maze,
  List<Dir> moves, {
  Pos? from,
  Set<Pos>? visited,
  bool stopAtGoal = false,
}) {
  final walker = Walker(maze, start: from, visited: visited);
  final optimal = maze.optimalMoves(from: walker.pos);
  final steps = <StepResult>[];
  var validPrefix = 0;
  var optimalPrefix = 0;
  var validRun = true;
  var optimalRun = true;
  MoveError? firstError;
  var completed = false;
  var truncated = false;
  final optimalMatch = <bool>[];

  for (var i = 0; i < moves.length; i++) {
    final move = moves[i];
    final result = walker.apply(move);
    steps.add(result);
    // Past the optimal sequence's terminal NONE, the only right answer is NONE.
    final wanted = i < optimal.length ? optimal[i] : Dir.none;
    optimalMatch.add(move == wanted);
    if (result.ok && validRun) {
      validPrefix++;
    } else if (!result.ok) {
      validRun = false;
      firstError ??= result.error;
    }
    if (optimalRun && i < optimal.length && optimal[i] == move) {
      optimalPrefix++;
    } else {
      optimalRun = false;
    }
    if (move == Dir.none) {
      completed = result.ok;
      truncated = true;
      break;
    }
    if (stopAtGoal && result.ok && result.atGoal) {
      completed = true;
      break;
    }
  }

  return SequenceEval(
    steps: steps,
    validPrefix: validPrefix,
    optimalPrefix: optimalPrefix,
    firstError: firstError,
    completed: completed,
    truncatedAtNone: truncated,
    optimalRemaining: optimal.length - 1,
    optimalMatch: optimalMatch,
  );
}
