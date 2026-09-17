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

/// The state handed to Jev: everything the model needs is here so the
/// questions can be terse. [walker] supplies the current position and trail.
Map<String, Object?> buildState(
  Maze maze,
  Walker walker, {
  bool showTrail = true,
}) {
  final trail = showTrail ? walker.visited.difference({walker.pos}) : <Pos>{};
  return {
    'task':
        'You are navigating an ASCII maze. Plan the sequence of moves that takes '
            '@ (your current position) to G (the goal) along the shortest route. '
            'The maze is a perfect maze: exactly one route exists between any two '
            'open positions, so the shortest route is unique.',
    'grid_rules': {
      'coordinates': 'row 0 is the top line, col 0 is the leftmost character.',
      'movement': 'Each move shifts @ by exactly one character: UP is row-1, '
          'DOWN is row+1, LEFT is col-1, RIGHT is col+1.',
      'walls': 'You can never move onto a # character or off the grid.',
      'revisits': 'Never move back onto a position you have already visited.',
      'finish': 'Once @ stands on G, every remaining move is NONE.',
    },
    'legend': {
      '#': 'wall',
      ' ': 'open floor',
      '@': 'your current position',
      'G': 'the goal',
      if (showTrail) '.': 'open floor you already visited',
    },
    'questions':
        'Each question asks for one move in the planned sequence, numbered from '
            'the current position: question 1 is the very next move, question 2 '
            'the move after that, and so on. Answer every question with one of '
            'UP, DOWN, LEFT, RIGHT, NONE.',
    'position': {'row': walker.pos.r, 'col': walker.pos.c},
    'goal': {'row': maze.goal.r, 'col': maze.goal.c},
    'moves_so_far': walker.steps,
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
