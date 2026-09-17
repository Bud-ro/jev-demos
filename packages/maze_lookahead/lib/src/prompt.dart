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
  described;

  static Phrasing parse(String s) => Phrasing.values.byName(s);
}

const _describedCriteria = <String, String?>{
  'UP': 'Move one character up (row - 1).',
  'DOWN': 'Move one character down (row + 1).',
  'LEFT': 'Move one character left (col - 1).',
  'RIGHT': 'Move one character right (col + 1).',
  'NONE': 'Do not move. Only correct once @ is standing on G.',
};

const _bareCriteria = <String, String?>{
  'UP': null,
  'DOWN': null,
  'LEFT': null,
  'RIGHT': null,
  'NONE': null,
};

/// Builds the Choice question for move number [n] (1-based).
Choice stepQuestion(Phrasing phrasing, int n) => switch (phrasing) {
      Phrasing.bare => Choice('$n', _bareCriteria),
      Phrasing.step => Choice('Step $n', _bareCriteria),
      Phrasing.move => Choice('Move for step $n', _bareCriteria),
      Phrasing.question => Choice(
          'What should be move number $n from the current position?',
          _bareCriteria,
        ),
      Phrasing.described => Choice('Step $n', _describedCriteria),
    };

/// Question id for step [n]. Ids are for code only; not sent to the model.
String stepId(int n) => 's$n';

/// Builds `k` step questions, 1..k.
Map<String, Question> stepQuestions(Phrasing phrasing, int k) => {
      for (var n = 1; n <= k; n++) stepId(n): stepQuestion(phrasing, n),
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
  });

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

  StateOptions copyWith({bool? trail}) => StateOptions(
        coordinates: coordinates,
        movesSoFar: movesSoFar,
        neighbors: neighbors,
        trail: trail ?? this.trail,
        leanRules: leanRules,
      );

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
Map<String, String> adjacentTiles(Maze maze, Walker walker) => {
      for (final d in Dir.moves)
        d.label: () {
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
  final legend = {
    '#': 'wall',
    ' ': 'open floor',
    '@': 'your current position',
    'G': 'the goal',
    if (options.trail) '.': 'open floor you already visited',
  };
  if (options.leanRules) {
    return {
      'task': 'Navigate the ASCII maze from @ to G by the shortest route. '
          'UP, DOWN, LEFT and RIGHT each move @ one character. Never move onto '
          '# and never back onto a visited tile. Answer NONE only when @ is '
          'standing on G. Question N asks for the Nth move from the current '
          'position: 1 is the next move, 2 the one after it, and so on.',
      'legend': legend,
      if (options.neighbors) 'adjacent': adjacentTiles(maze, walker),
      'maze': maze.renderString(at: walker.pos, trail: trail),
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
      'movement': 'Each move shifts @ by exactly one character: UP is row-1, '
          'DOWN is row+1, LEFT is col-1, RIGHT is col+1.',
      'walls': 'You can never move onto a # character or off the grid.',
      'revisits': 'Never move back onto a position you have already visited.',
      'finish': 'Once @ stands on G, every remaining move is NONE.',
    },
    'legend': legend,
    'questions':
        'Each question asks for one move in the planned sequence, numbered from '
            'the current position: question 1 is the very next move, question 2 '
            'the move after that, and so on. Answer every question with one of '
            'UP, DOWN, LEFT, RIGHT, NONE.',
    if (options.coordinates) 'position': {'row': walker.pos.r, 'col': walker.pos.c},
    if (options.coordinates) 'goal': {'row': maze.goal.r, 'col': maze.goal.c},
    if (options.movesSoFar) 'moves_so_far': walker.steps,
    if (options.neighbors) 'adjacent': adjacentTiles(maze, walker),
    'maze': maze.renderString(at: walker.pos, trail: trail),
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
