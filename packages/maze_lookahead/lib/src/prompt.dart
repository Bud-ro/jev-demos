import 'package:jev_common/jev_common.dart';

import 'maze.dart';
import 'sim.dart';

/// How each "step N" question is worded. Context lives in the state, so the
/// question can be as terse as the bare number.
enum Phrasing {
  /// `"3"`
  bare,

  /// `"Step 3"`
  step,

  /// `"Move for step 3"`
  move,

  /// `"What should be move number 3 from the current position?"`
  question,

  /// `"Step 3"` plus a description on every option.
  described,

  /// `"Which direction should @ move next to reach G by the shortest route?"`
  /// (move 1) and `"... on move number 3 ..."` for later steps. Closest to a
  /// plain next-move query.
  direct;

  static Phrasing parse(String s) => Phrasing.values.byName(s);
}

Map<String, String?> _criteria(DirLabels labels, bool includeNone,
    {bool described = false}) {
  String? desc(Dir d) => !described
      ? null
      : switch (d) {
          Dir.up => 'Move one character up (row - 1).',
          Dir.down => 'Move one character down (row + 1).',
          Dir.left => 'Move one character left (col - 1).',
          Dir.right => 'Move one character right (col + 1).',
          Dir.none => 'Do not move. Only correct once @ is standing on G.',
        };
  return {
    for (final d in Dir.moves) d.labelFor(labels): desc(d),
    if (includeNone) Dir.none.labelFor(labels): desc(Dir.none),
  };
}

/// Builds the Choice question for move number [n] (1-based).
Choice stepQuestion(
  Phrasing phrasing,
  int n, {
  DirLabels labels = DirLabels.arrows,
  bool includeNone = true,
}) {
  final c = _criteria(labels, includeNone);
  return switch (phrasing) {
    Phrasing.bare => Choice('$n', c),
    Phrasing.step => Choice('Step $n', c),
    Phrasing.move => Choice('Move for step $n', c),
    Phrasing.question => Choice(
        'What should be move number $n from the current position?', c),
    Phrasing.described =>
      Choice('Step $n', _criteria(labels, includeNone, described: true)),
    Phrasing.direct => Choice(
        n == 1
            ? 'Which direction should @ move next to reach G by the shortest route?'
            : 'Which direction should @ move on move number $n (counting from '
                'the current position, 1 being the very next move) to reach G '
                'by the shortest route?',
        c),
  };
}

/// Question id for step [n]. Ids are for code only; not sent to the model.
String stepId(int n) => 's$n';

/// Builds `k` step questions, 1..k.
Map<String, Question> stepQuestions(
  Phrasing phrasing,
  int k, {
  DirLabels labels = DirLabels.arrows,
  bool includeNone = true,
}) =>
    {
      for (var n = 1; n <= k; n++)
        stepId(n): stepQuestion(phrasing, n, labels: labels, includeNone: includeNone),
    };

/// Parses the step number back out of a question id.
int stepFromId(String id) => int.parse(id.substring(1));

/// Which pieces of context go into the state. Used to ablate what helps
/// and what misleads the model.
class StateOptions {
  const StateOptions({
    this.coordinates = true,
    this.movesSoFar = true,
    this.neighbors = false,
    this.trail = true,
    this.leanRules = false,
    this.labels = DirLabels.arrows,
    this.includeNone = true,
    this.wall = '#',
  });

  /// Character used for walls in the rendered maze and the legend.
  final String wall;

  /// Include `position` and `goal` row/col plus the coordinate rule.
  final bool coordinates;

  /// Include the `moves_so_far` counter.
  final bool movesSoFar;

  /// Describe the four adjacent tiles (wall / open / visited / goal).
  final bool neighbors;

  /// Draw visited tiles as `.`.
  final bool trail;

  /// Replace the long task/rules text with a few short lines.
  final bool leanRules;

  /// Direction naming used in both the state text and the questions.
  final DirLabels labels;

  /// Offer NONE as an answer. Without it, code detects the goal.
  final bool includeNone;

  StateOptions copyWith(
          {bool? trail, DirLabels? labels, bool? includeNone, String? wall}) =>
      StateOptions(
        coordinates: coordinates,
        movesSoFar: movesSoFar,
        neighbors: neighbors,
        trail: trail ?? this.trail,
        leanRules: leanRules,
        labels: labels ?? this.labels,
        includeNone: includeNone ?? this.includeNone,
        wall: wall ?? this.wall,
      );

  /// The answer labels in display order.
  List<String> get answerLabels => [
        for (final d in Dir.moves) d.labelFor(labels),
        if (includeNone) Dir.none.labelFor(labels),
      ];

  /// Named variants for `--state` and the `ablate` command.
  static const variants = <String, StateOptions>{
    'baseline': StateOptions(),
    'nocoords': StateOptions(coordinates: false),
    'minimal': StateOptions(coordinates: false, movesSoFar: false),
    'neighbors': StateOptions(
        coordinates: false, movesSoFar: false, neighbors: true),
    'neighbors_coords': StateOptions(movesSoFar: false, neighbors: true),
    'lean': StateOptions(
        coordinates: false, movesSoFar: false, neighbors: true, leanRules: true),
  };

  static StateOptions named(String name) {
    final v = variants[name];
    if (v == null) {
      throw ArgumentError('Unknown state variant: $name '
          '(one of ${variants.keys.join(', ')})');
    }
    return v;
  }
}

/// What sits on the tile one step in each direction from the walker.
Map<String, String> adjacentTiles(Maze maze, Walker walker,
        {DirLabels labels = DirLabels.arrows}) =>
    {
      for (final d in Dir.moves)
        d.labelFor(labels): () {
          final p = d.apply(walker.pos);
          if (maze.isWall(p)) return 'wall';
          if (p == maze.goal) return 'goal';
          if (walker.visited.contains(p)) return 'visited';
          return 'open';
        }(),
    };

/// The state handed to Jev: everything the model needs is here so the
/// questions can be terse. [walker] supplies the current position and trail.
Map<String, Object?> buildState(
  Maze maze,
  Walker walker, {
  StateOptions options = const StateOptions(),
}) {
  final trail = options.trail ? walker.visited.difference({walker.pos}) : <Pos>{};
  final wall = options.wall;
  final legend = {
    wall: 'wall',
    ' ': 'open floor',
    '@': 'your current position',
    'G': 'the goal',
    if (options.trail) '.': 'open floor you already visited',
  };
  final l = options.labels;
  final up = Dir.up.labelFor(l), down = Dir.down.labelFor(l);
  final left = Dir.left.labelFor(l), right = Dir.right.labelFor(l);
  final none = Dir.none.labelFor(l);
  if (options.leanRules) {
    return {
      'task': 'Navigate the ASCII maze from @ to G by the shortest route. '
          '$up, $down, $left and $right each move @ one character. Never move '
          'onto $wall and never back onto a visited tile. '
          '${options.includeNone ? 'Answer $none only when @ is standing on G. ' : ''}'
          'Question N asks for the Nth move from the current '
          'position: 1 is the next move, 2 the one after it, and so on.',
      'legend': legend,
      if (options.neighbors) 'adjacent': adjacentTiles(maze, walker, labels: l),
      'maze': maze.renderString(at: walker.pos, trail: trail, wallChar: wall),
    };
  }
  return {
    'task':
        'You are navigating an ASCII maze. Plan the sequence of moves that takes '
            '@ (your current position) to G (the goal) along the shortest route. '
            'The maze is a perfect maze: exactly one route exists between any two '
            'open positions, so the shortest route is unique.',
    'grid_rules': {
      if (options.coordinates)
        'coordinates': 'row 0 is the top line, col 0 is the leftmost character.',
      'movement': 'Each move shifts @ by exactly one character: $up is row-1, '
          '$down is row+1, $left is col-1, $right is col+1.',
      'walls': 'You can never move onto a $wall character or off the grid.',
      'revisits': 'Never move back onto a position you have already visited.',
      if (options.includeNone)
        'finish': 'Once @ stands on G, every remaining move is $none.',
    },
    'legend': legend,
    'questions':
        'Each question asks for one move in the planned sequence, numbered from '
            'the current position: question 1 is the very next move, question 2 '
            'the move after that, and so on. Answer every question with one of '
            '${options.answerLabels.join(', ')}.',
    if (options.coordinates) 'position': {'row': walker.pos.r, 'col': walker.pos.c},
    if (options.coordinates) 'goal': {'row': maze.goal.r, 'col': maze.goal.c},
    if (options.movesSoFar) 'moves_so_far': walker.steps,
    if (options.neighbors) 'adjacent': adjacentTiles(maze, walker, labels: l),
    'maze': maze.renderString(at: walker.pos, trail: trail, wallChar: wall),
  };
}

/// Extracts the chosen direction for every step question in [answers],
/// ordered by step number.
List<Dir> answersToMoves(Map<String, Answer> answers) {
  final ids = answers.keys.where((k) => k.startsWith('s')).toList()
    ..sort((a, b) => stepFromId(a).compareTo(stepFromId(b)));
  return [
    for (final id in ids) Dir.fromLabel((answers[id] as ChoiceAnswer).choice),
  ];
}
