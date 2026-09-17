import 'dart:math' as math;

/// A grid coordinate on the character grid (row, col).
typedef Pos = ({int r, int c});

/// Movement on the character grid. One move = one character.
enum Dir {
  up(-1, 0, 'UP'),
  down(1, 0, 'DOWN'),
  left(0, -1, 'LEFT'),
  right(0, 1, 'RIGHT'),
  none(0, 0, 'NONE');

  const Dir(this.dr, this.dc, this.label);
  final int dr;
  final int dc;
  final String label;

  static Dir fromLabel(String s) => Dir.values.firstWhere(
        (d) => d.label == s.toUpperCase(),
        orElse: () => throw ArgumentError('Unknown direction: $s'),
      );

  static const moves = [Dir.up, Dir.down, Dir.left, Dir.right];

  Pos apply(Pos p) => (r: p.r + dr, c: p.c + dc);

  Dir get opposite => switch (this) {
        Dir.up => Dir.down,
        Dir.down => Dir.up,
        Dir.left => Dir.right,
        Dir.right => Dir.left,
        Dir.none => Dir.none,
      };
}

/// A perfect maze (spanning tree) of `size x size` cells rendered on a
/// `(2*size+1)` square character grid. Every character is a position: `#`
/// is a wall, anything else is walkable. Cells sit at odd coordinates and
/// passages between them at even ones, so one cell-to-cell hop is two moves.
class Maze {
  Maze._(this.size, this._wall, this.start, this.goal, this.seed, this.algo);

  /// Parses a rendered grid (as produced by [render]). `@` marks the current
  /// position and `G` the goal; if `@` is absent (or sits on `G`) pass
  /// [at]/[goalAt] explicitly.
  factory Maze.parse(List<String> lines, {Pos? at, Pos? goalAt}) {
    final w = lines.first.length;
    final size = (w - 1) ~/ 2;
    final wall = List.generate(
      lines.length,
      (r) => List.generate(w, (c) => lines[r][c] == '#'),
    );
    Pos? start = at, goal = goalAt;
    for (var r = 0; r < lines.length; r++) {
      for (var c = 0; c < w; c++) {
        if (lines[r][c] == '@' && start == null) start = (r: r, c: c);
        if (lines[r][c] == 'G' && goal == null) goal = (r: r, c: c);
      }
    }
    if (start == null || goal == null) {
      throw ArgumentError('Could not locate @ and G in the grid');
    }
    return Maze._(size, wall, start, goal, -1, 'parsed');
  }

  /// Generates a perfect maze. [algo] is `prim` (many short dead ends,
  /// solution length roughly proportional to `size`) or `dfs` (long winding
  /// corridors, solution length closer to `size^2`).
  factory Maze.generate(int size, {required int seed, String algo = 'prim'}) {
    if (size < 2) throw ArgumentError('size must be >= 2');
    final rng = math.Random(seed);
    final w = 2 * size + 1;
    final wall = List.generate(w, (_) => List.filled(w, true));

    void carveCell(int cr, int cc) => wall[2 * cr + 1][2 * cc + 1] = false;
    void carveBetween(int r1, int c1, int r2, int c2) =>
        wall[r1 + r2 + 1][c1 + c2 + 1] = false;

    final inMaze = List.generate(size, (_) => List.filled(size, false));
    List<(int, int)> neighbours(int r, int c) => [
          if (r > 0) (r - 1, c),
          if (r < size - 1) (r + 1, c),
          if (c > 0) (r, c - 1),
          if (c < size - 1) (r, c + 1),
        ];

    switch (algo) {
      case 'prim':
        final frontier = <(int, int)>[];
        void add(int r, int c) {
          inMaze[r][c] = true;
          carveCell(r, c);
          for (final (nr, nc) in neighbours(r, c)) {
            if (!inMaze[nr][nc]) frontier.add((nr, nc));
          }
        }

        add(0, 0);
        while (frontier.isNotEmpty) {
          final idx = rng.nextInt(frontier.length);
          final (r, c) = frontier[idx];
          frontier[idx] = frontier.last;
          frontier.removeLast();
          if (inMaze[r][c]) continue;
          final linked = neighbours(r, c).where((n) => inMaze[n.$1][n.$2]).toList();
          final (lr, lc) = linked[rng.nextInt(linked.length)];
          carveBetween(r, c, lr, lc);
          add(r, c);
        }
      case 'dfs':
        final stack = <(int, int)>[(0, 0)];
        inMaze[0][0] = true;
        carveCell(0, 0);
        while (stack.isNotEmpty) {
          final (r, c) = stack.last;
          final options = neighbours(r, c).where((n) => !inMaze[n.$1][n.$2]).toList();
          if (options.isEmpty) {
            stack.removeLast();
            continue;
          }
          final (nr, nc) = options[rng.nextInt(options.length)];
          inMaze[nr][nc] = true;
          carveCell(nr, nc);
          carveBetween(r, c, nr, nc);
          stack.add((nr, nc));
        }
      default:
        throw ArgumentError('Unknown algo: $algo (use prim or dfs)');
    }

    return Maze._(size, wall, (r: 1, c: 1), (r: w - 2, c: w - 2), seed, algo);
  }

  /// Cells per side.
  final int size;
  final List<List<bool>> _wall;
  final Pos start;
  final Pos goal;
  final int seed;
  final String algo;

  /// Characters per side.
  int get width => 2 * size + 1;

  /// Total characters in the rendered grid, excluding newlines.
  int get charCount => width * width;

  bool inBounds(Pos p) => p.r >= 0 && p.c >= 0 && p.r < width && p.c < width;
  bool isWall(Pos p) => !inBounds(p) || _wall[p.r][p.c];
  bool isOpen(Pos p) => !isWall(p);

  List<List<int>>? _dist;

  /// Shortest-path distance (in moves) from every open position to [goal].
  /// Walls are -1.
  List<List<int>> get distances {
    if (_dist != null) return _dist!;
    final d = List.generate(width, (_) => List.filled(width, -1));
    final queue = <Pos>[goal];
    d[goal.r][goal.c] = 0;
    var head = 0;
    while (head < queue.length) {
      final p = queue[head++];
      for (final dir in Dir.moves) {
        final n = dir.apply(p);
        if (isOpen(n) && d[n.r][n.c] < 0) {
          d[n.r][n.c] = d[p.r][p.c] + 1;
          queue.add(n);
        }
      }
    }
    return _dist = d;
  }

  int distanceFrom(Pos p) => inBounds(p) ? distances[p.r][p.c] : -1;

  /// The unique optimal move sequence from [from] to the goal, terminated by
  /// [Dir.none]. Returns just `[none]` when already on the goal.
  List<Dir> optimalMoves({Pos? from}) {
    var p = from ?? start;
    final out = <Dir>[];
    var d = distanceFrom(p);
    if (d < 0) throw ArgumentError('Position $p is not walkable');
    while (d > 0) {
      for (final dir in Dir.moves) {
        final n = dir.apply(p);
        if (isOpen(n) && distances[n.r][n.c] == d - 1) {
          out.add(dir);
          p = n;
          d--;
          break;
        }
      }
    }
    out.add(Dir.none);
    return out;
  }

  /// Positions along the optimal path from [start] to [goal] inclusive.
  List<Pos> solutionPath() {
    var p = start;
    final path = [p];
    for (final m in optimalMoves()) {
      if (m == Dir.none) break;
      p = m.apply(p);
      path.add(p);
    }
    return path;
  }

  /// Number of moves in the optimal solution from [start].
  int get solutionLength => distanceFrom(start);

  /// Renders the grid. [at] is drawn as `@`, [goal] as `G` (unless `@` sits on
  /// it), and [trail] positions as `.`.
  List<String> render({Pos? at, Set<Pos> trail = const {}}) {
    final lines = <String>[];
    for (var r = 0; r < width; r++) {
      final sb = StringBuffer();
      for (var c = 0; c < width; c++) {
        final p = (r: r, c: c);
        if (at != null && p == at) {
          sb.write('@');
        } else if (p == goal) {
          sb.write('G');
        } else if (_wall[r][c]) {
          sb.write('#');
        } else if (trail.contains(p)) {
          sb.write('.');
        } else {
          sb.write(' ');
        }
      }
      lines.add(sb.toString());
    }
    return lines;
  }

  String renderString({Pos? at, Set<Pos> trail = const {}}) =>
      render(at: at, trail: trail).join('\n');

  Map<String, Object?> toJson() => {
        'size': size,
        'width': width,
        'seed': seed,
        'algo': algo,
        'start': [start.r, start.c],
        'goal': [goal.r, goal.c],
        'solutionLength': solutionLength,
        'solution': solutionPath().map((p) => [p.r, p.c]).toList(),
        'grid': render(),
      };
}
