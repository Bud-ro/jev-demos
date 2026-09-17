import 'dart:math' as math;

/// Compass direction on the cell grid.
enum Dir4 {
  n(-1, 0, 'N'),
  e(0, 1, 'E'),
  s(1, 0, 'S'),
  w(0, -1, 'W');

  const Dir4(this.dr, this.dc, this.label);
  final int dr;
  final int dc;
  final String label;

  static Dir4 fromLabel(String s) =>
      Dir4.values.firstWhere((d) => d.label == s.toUpperCase());
}

/// An `n x n` grid of cells with row-major ids `0 .. n*n-1`, start at 0 and
/// goal at `n*n-1`, stored as an adjacency list of open passages. This is a
/// port of `public/maze.js` from pahndev/Type-Safe-Maze-Demo-: randomized
/// DFS carves a spanning tree, then each missing passage is opened with
/// probability [extra] so the maze has cycles and alternate routes.
class CellMaze {
  CellMaze._(this.n, this.exits, this.seed, this.extra);

  factory CellMaze.generate(int n, {required int seed, double extra = 0.12}) {
    final rng = math.Random(seed);
    final cells = n * n;
    final exits = List.generate(cells, (_) => <int>[]);
    void connect(int a, int b) {
      exits[a].add(b);
      exits[b].add(a);
    }

    final seen = <int>{0};
    final stack = <int>[0];
    while (stack.isNotEmpty) {
      final current = stack.last;
      final options = adjacent(current, n).where((c) => !seen.contains(c)).toList();
      if (options.isEmpty) {
        stack.removeLast();
        continue;
      }
      final next = options[rng.nextInt(options.length)];
      connect(current, next);
      seen.add(next);
      stack.add(next);
    }
    for (var cell = 0; cell < cells; cell++) {
      for (final next in adjacent(cell, n)) {
        if (next > cell && !exits[cell].contains(next) && rng.nextDouble() < extra) {
          connect(cell, next);
        }
      }
    }
    return CellMaze._(n, exits, seed, extra);
  }

  /// Cells per side.
  final int n;

  /// Open passages per cell, in carve order (as the original does).
  final List<List<int>> exits;
  final int seed;
  final double extra;

  int get cells => n * n;
  int get start => 0;
  int get goal => cells - 1;

  /// Grid neighbours in up, right, down, left order (same as the original).
  static List<int> adjacent(int cell, int n) {
    final row = cell ~/ n, col = cell % n;
    return [
      if (row > 0) cell - n,
      if (col < n - 1) cell + 1,
      if (row < n - 1) cell + n,
      if (col > 0) cell - 1,
    ];
  }

  /// 1-indexed (row, column), as the original reports them.
  (int, int) rowCol(int cell) => (cell ~/ n + 1, cell % n + 1);

  /// The cell one step in [d] from [from], or null if that passage is closed.
  int? step(int from, Dir4 d) {
    final r = from ~/ n + d.dr, c = from % n + d.dc;
    if (r < 0 || c < 0 || r >= n || c >= n) return null;
    final to = r * n + c;
    return exits[from].contains(to) ? to : null;
  }

  Dir4 dirTo(int from, int to) {
    final dr = to ~/ n - from ~/ n, dc = to % n - from % n;
    return Dir4.values.firstWhere((d) => d.dr == dr && d.dc == dc);
  }

  List<int>? _dist;

  /// BFS distance from every cell to the goal.
  List<int> get distances {
    if (_dist != null) return _dist!;
    final d = List.filled(cells, -1);
    final queue = <int>[goal];
    d[goal] = 0;
    for (var head = 0; head < queue.length; head++) {
      final c = queue[head];
      for (final next in exits[c]) {
        if (d[next] < 0) {
          d[next] = d[c] + 1;
          queue.add(next);
        }
      }
    }
    return _dist = d;
  }

  int distance(int cell) => distances[cell];
  int get optimalMoves => distance(start);

  /// Any neighbour that is one step closer to the goal (ties possible with
  /// cycles). Null on the goal.
  Set<int> bestHops(int from) => {
        for (final next in exits[from])
          if (distances[next] == distances[from] - 1) next,
      };

  /// The optimal move sequence from [from] as directions, one shortest path.
  List<Dir4> optimalDirections({int? from}) {
    var c = from ?? start;
    final out = <Dir4>[];
    while (c != goal) {
      final next = bestHops(c).reduce((a, b) => a < b ? a : b);
      out.add(dirTo(c, next));
      c = next;
    }
    return out;
  }

  List<int> optimalPath() {
    var c = start;
    final path = [c];
    while (c != goal) {
      c = bestHops(c).reduce((a, b) => a < b ? a : b);
      path.add(c);
    }
    return path;
  }

  /// ASCII rendering for logs and later GIFs: `(2n+1)` square, `#` walls.
  List<String> render({int? at, Set<int> visited = const {}}) {
    final w = 2 * n + 1;
    final g = List.generate(w, (_) => List.filled(w, '#'));
    for (var cell = 0; cell < cells; cell++) {
      final r = 2 * (cell ~/ n) + 1, c = 2 * (cell % n) + 1;
      g[r][c] = cell == at
          ? '@'
          : cell == goal
              ? 'G'
              : visited.contains(cell)
                  ? '.'
                  : ' ';
      for (final next in exits[cell]) {
        if (next > cell) {
          final nr = 2 * (next ~/ n) + 1, nc = 2 * (next % n) + 1;
          g[(r + nr) ~/ 2][(c + nc) ~/ 2] = ' ';
        }
      }
    }
    return g.map((row) => row.join()).toList();
  }

  Map<String, Object?> toJson() => {
        'n': n,
        'seed': seed,
        'extra': extra,
        'optimalMoves': optimalMoves,
        'optimalPath': optimalPath(),
        'exits': exits,
        'grid': render(),
      };
}

/// Code-only baselines run under the same cap, so Jev's result can be read
/// against chance. `random` picks a uniformly random exit; `unvisited` picks
/// uniformly among the least-visited exits (a one-line exploration policy).
class Baseline {
  const Baseline(this.policy, this.solveRate, this.meanMovesSolved, this.runs);
  final String policy;
  final double solveRate;
  final double? meanMovesSolved;
  final int runs;

  Map<String, Object?> toJson() => {
        'policy': policy,
        'solveRate': solveRate,
        'meanMovesSolved': meanMovesSolved,
        'runs': runs,
      };
}

Baseline simulateBaseline(
  CellMaze m, {
  required String policy,
  required int cap,
  int runs = 2000,
  int seed = 7,
}) {
  final rng = math.Random(seed);
  var solved = 0;
  var movesSum = 0;
  for (var run = 0; run < runs; run++) {
    final visits = List.filled(m.cells, 0);
    var cell = m.start;
    visits[cell] = 1;
    var moves = 0;
    while (cell != m.goal && moves < cap) {
      final ex = m.exits[cell];
      List<int> pool;
      if (policy == 'unvisited') {
        final minV = ex.map((c) => visits[c]).reduce(math.min);
        pool = ex.where((c) => visits[c] == minV).toList();
      } else {
        pool = ex;
      }
      cell = pool[rng.nextInt(pool.length)];
      visits[cell]++;
      moves++;
    }
    if (cell == m.goal) {
      solved++;
      movesSum += moves;
    }
  }
  return Baseline(policy, solved / runs, solved == 0 ? null : movesSum / solved, runs);
}
