import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:jev_common/jev_common.dart';
import 'package:maze_lookahead/maze_lookahead.dart';

const _usage = '''
maze_lookahead: how far ahead can Jev plan moves through an ASCII maze?

Usage: dart run maze_lookahead [options] <command> [args]

Commands
  all            probe -> phrasing -> independence -> sweep -> analyze
  probe          find which maze sizes fit and how many step questions ride along
  phrasing       compare question wordings on small mazes
  independence   check that asking more questions does not change earlier answers
  sweep          the main loop: ask k steps, apply step 1, repeat (records everything)
  analyze <dir>  re-run the analysis on an existing results directory
  plan           napkin math: worst-case calls and time for the chosen preset
  show           print a maze, the state JSON, and sample questions

Every API call is made sequentially; nothing runs in parallel.
''';

void main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('preset', abbr: 'p', defaultsTo: 'quick',
        allowed: ['smoke', 'quick', 'full'], help: 'Size/trial/cap preset.')
    ..addOption('k', help: 'Max step questions per request (default from preset).')
    ..addOption('sizes', help: 'Override sweep sizes, e.g. 5,10,20.')
    ..addOption('trials', help: 'Override trials per size.')
    ..addOption('iter-cap',
        help: 'Override the per-episode sparsity cap; "none" leaves only the '
            '5x-optimal hard cap.')
    ..addOption('phrasing',
        allowed: Phrasing.values.map((p) => p.name).toList(),
        help: 'Force a question phrasing instead of using the phrasing winner.')
    ..addOption('algo', allowed: ['prim', 'dfs'], help: 'Maze generator.')
    ..addFlag('trail', defaultsTo: true, help: 'Draw visited cells as "." in the maze.')
    ..addOption('seed', help: 'Base RNG seed for maze generation.')
    ..addOption('delay-ms', help: 'Pause between API calls.')
    ..addOption('budget-min', help: 'Hard time budget for the run in minutes.')
    ..addOption('out', help: 'Results base directory (default: <package>/results).')
    ..addOption('label', help: 'Suffix for the run directory name.')
    ..addFlag('mock', help: 'Use the offline oracle instead of the real API.')
    ..addOption('mock-accuracy', defaultsTo: '0.95')
    ..addOption('mock-decay', defaultsTo: '0.97')
    ..addOption('mock-latency-ms', defaultsTo: '0')
    ..addOption('size', defaultsTo: '5', help: 'Maze size for "show".')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(_usage);
    stderr.writeln(parser.usage);
    exit(64);
  }
  if (args['help'] as bool || args.rest.isEmpty) {
    print(_usage);
    print(parser.usage);
    return;
  }

  final command = args.rest.first;
  final cfg = _configFrom(args);

  switch (command) {
    case 'show':
      _show(cfg, int.parse(args['size'] as String));
    case 'plan':
      _plan(cfg, args.rest.length > 1 ? Directory(args.rest[1]) : null);
    case 'analyze':
      if (args.rest.length < 2) {
        stderr.writeln('analyze needs a results directory');
        exit(64);
      }
      final analysis = await analyzeRun(Directory(args.rest[1]));
      print(analysis.report);
    case 'all':
    case 'probe':
    case 'phrasing':
    case 'independence':
    case 'sweep':
      await _runPhases(cfg, args, command);
    default:
      stderr.writeln('Unknown command: $command');
      stderr.writeln(_usage);
      exit(64);
  }
}

DemoConfig _configFrom(ArgResults args) {
  var cfg = DemoConfig.named(args['preset'] as String);
  final out = args['out'] as String? ?? _defaultOut();
  cfg = cfg.copyWith(outBase: out);

  if (args['k'] != null) cfg = cfg.copyWith(k: int.parse(args['k'] as String));
  if (args['phrasing'] != null) {
    cfg = cfg.copyWith(phrasing: Phrasing.parse(args['phrasing'] as String));
  }
  if (args['algo'] != null) cfg = cfg.copyWith(algo: args['algo'] as String);
  cfg = cfg.copyWith(showTrail: args['trail'] as bool);
  if (args['seed'] != null) cfg = cfg.copyWith(seed: int.parse(args['seed'] as String));
  if (args['delay-ms'] != null) {
    cfg = cfg.copyWith(delay: Duration(milliseconds: int.parse(args['delay-ms'] as String)));
  }
  if (args['budget-min'] != null) {
    cfg = cfg.copyWith(timeBudget: Duration(minutes: int.parse(args['budget-min'] as String)));
  }
  if (args['label'] != null) cfg = cfg.copyWith(label: args['label'] as String);

  var plan = cfg.plan;
  if (args['sizes'] != null) {
    final sizes = (args['sizes'] as String).split(',').map((s) => int.parse(s.trim()));
    plan = [
      for (final s in sizes)
        plan.where((p) => p.size == s).firstOrNull ?? SizePlan(s, trials: 3, iterCap: 30),
    ];
  }
  if (args['trials'] != null) {
    final t = int.parse(args['trials'] as String);
    plan = [for (final p in plan) SizePlan(p.size, trials: t, iterCap: p.iterCap)];
  }
  if (args['iter-cap'] != null) {
    final raw = args['iter-cap'] as String;
    final cap = raw == 'none' ? null : int.parse(raw);
    plan = [for (final p in plan) SizePlan(p.size, trials: p.trials, iterCap: cap)];
  }
  return cfg.copyWith(plan: plan);
}

/// `<package>/results` when run from the repo root or the package dir,
/// else `results` under the cwd.
String _defaultOut() {
  final cwd = Directory.current.path;
  if (Directory('$cwd/packages/maze_lookahead').existsSync()) {
    return 'packages/maze_lookahead/results';
  }
  return 'results';
}

void _show(DemoConfig cfg, int size) {
  final maze = Maze.generate(size, seed: cfg.seed + size * 1000, algo: cfg.algo);
  final walker = Walker(maze);
  final state = buildState(maze, walker, showTrail: cfg.showTrail);
  print('size=$size grid=${maze.width}x${maze.width} chars=${maze.charCount} '
      'optimalMoves=${maze.solutionLength} hardCap=${DemoConfig.hardCapMultiplier * maze.solutionLength}');
  print('');
  print(maze.renderString(at: walker.pos));
  print('');
  print('state (${jsonEncode(state).length} chars as JSON):');
  print(const JsonEncoder.withIndent('  ').convert(state));
  print('');
  for (final p in Phrasing.values) {
    final q = stepQuestions(p, 2);
    print('phrasing ${p.name}: ${jsonEncode(q)}');
  }
  print('');
  print('optimal moves: ${maze.optimalMoves().map((d) => d.label).join(' ')}');
}

void _plan(DemoConfig cfg, Directory? measuredFrom) {
  // Latency guesses per size (seconds) until a probe measures them.
  const guess = {5: 0.3, 10: 0.35, 20: 0.5, 50: 1.0, 100: 2.0, 200: 4.0, 500: 6.0, 1000: 8.0};
  Map<String, dynamic>? meta;
  if (measuredFrom != null) {
    final f = File('${measuredFrom.path}/run.json');
    if (f.existsSync()) meta = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }
  final measuredLatency = (meta?['probeLatencyMs'] as Map<String, dynamic>?) ?? const {};
  final measuredTokens = (meta?['probeInputTokens'] as Map<String, dynamic>?) ?? const {};
  final feasible = (meta?['feasibleK'] as Map<String, dynamic>?) ?? const {};

  print('Napkin math for preset "${cfg.preset}" (k=${cfg.k}, '
      'time budget ${cfg.timeBudget.inMinutes} min, hard cap = '
      '${DemoConfig.hardCapMultiplier} x optimal moves)');
  print('');
  final rows = <List<String>>[];
  var totalCalls = 0;
  var totalSec = 0.0;
  for (final p in cfg.plan) {
    final maze = Maze.generate(p.size, seed: cfg.seed + p.size * 1000, algo: cfg.algo);
    final hard = DemoConfig.hardCapMultiplier * maze.solutionLength;
    final cap = p.iterCap == null ? hard : (p.iterCap! < hard ? p.iterCap! : hard);
    final worstCalls = p.trials * (cap + 1); // +1 for the at-goal NONE check
    final sec = (measuredLatency['${p.size}'] as num?)?.toDouble() ?? guess[p.size]! * 1000;
    final estTokens = (measuredTokens['${p.size}'] as num?)?.toInt() ??
        (maze.charCount / 2.5 + 400 + cfg.k * 12).round();
    final infeasible = feasible['${p.size}'] == 0 || estTokens > 32000;
    if (!infeasible) {
      totalCalls += worstCalls;
      totalSec += worstCalls * sec / 1000;
    }
    rows.add([
      '${p.size}',
      '${maze.width}x${maze.width}',
      '${maze.charCount}',
      '~$estTokens${infeasible ? ' (over)' : ''}',
      '${maze.solutionLength}',
      '${p.trials}',
      '$cap',
      '$worstCalls',
      '${(sec / 1000).toStringAsFixed(2)}s',
      infeasible ? 'skip' : '${(worstCalls * sec / 60000).toStringAsFixed(1)} min',
    ]);
  }
  print(_plainTable(
    ['size', 'grid', 'chars', 'inputTok', 'optimal', 'trials', 'cap', 'worstCalls', 'lat', 'worstTime'],
    rows,
  ));
  print('');
  final overhead = cfg.probeSizes.length +
      cfg.phrasingSizes.length * cfg.phrasingTrials * Phrasing.values.length +
      cfg.independenceTrials * cfg.independenceKs.length;
  print('sweep worst case: $totalCalls calls, ~${(totalSec / 60).toStringAsFixed(1)} min');
  print('probe + phrasing + independence: ~$overhead calls (small mazes, well under a minute)');
  print('Episodes end early on goal, on two consecutive stalls, or when the time budget');
  print('is hit, so the real run is usually well under the worst case.');
  print('Token estimate assumes ~2.5 maze chars per token; run "probe" to measure.');
}

Future<void> _runPhases(DemoConfig cfg, ArgResults args, String command) async {
  final mock = args['mock'] as bool;
  final startedAt = DateTime.now();
  final JevClient client;
  if (mock) {
    final oracle = MockJev(
      accuracy: double.parse(args['mock-accuracy'] as String),
      decay: double.parse(args['mock-decay'] as String),
      latency: Duration(milliseconds: int.parse(args['mock-latency-ms'] as String)),
      seed: cfg.seed,
    );
    client = JevClient(apiKey: 'mock', httpClient: oracle.client());
  } else {
    client = JevClient.fromEnv(loadEnv());
  }

  final label = '${cfg.label}${mock ? '-mock' : ''}${command == 'all' ? '' : '-$command'}';
  final run = RunDir.create(cfg.outBase, label);
  final logFile = run.file('log.txt').openWrite();
  void log(String line) {
    print(line);
    logFile.writeln(line);
  }

  log('run dir: ${run.path}');
  log('preset=${cfg.preset} k=${cfg.k} algo=${cfg.algo} trail=${cfg.showTrail} '
      'mock=$mock budget=${cfg.timeBudget.inMinutes}min');
  final exp = Experiment(cfg, client, run, log: log);
  final phases = <String>[];
  Phrasing? phrasing = cfg.phrasing;

  try {
    switch (command) {
      case 'probe':
        phases.add('probe');
        await exp.probe();
      case 'phrasing':
        phases.add('phrasing');
        phrasing = await exp.phrasingExperiment();
      case 'independence':
        phases.add('independence');
        await exp.independenceCheck(phrasing ?? Phrasing.bare);
      case 'sweep':
        phases.add('sweep');
        await exp.sweep(phrasing ?? Phrasing.bare);
      case 'all':
        phases.add('probe');
        await exp.probe();
        phases.add('phrasing');
        phrasing = await exp.phrasingExperiment();
        phases.add('independence');
        await exp.independenceCheck(phrasing);
        phases.add('sweep');
        await exp.sweep(phrasing);
    }
  } finally {
    await exp.writeRunMeta(
        startedAt: startedAt, phrasing: phrasing, mock: mock, phases: phases);
    await run.close();
    client.close();
    log('done: ${exp.calls} calls, ${exp.inputTokens} input tokens, '
        '${exp.clock.elapsed.inSeconds}s elapsed '
        '(${(exp.apiTime.inMilliseconds / 1000).toStringAsFixed(1)}s in API)');
    await logFile.close();
  }

  final analysis = await analyzeRun(run.dir);
  print('');
  print(analysis.report);
  print('summary: ${run.file('summary.json').path}');
}

String _plainTable(List<String> header, List<List<String>> rows) {
  final widths = List<int>.generate(header.length, (i) => header[i].length);
  for (final row in rows) {
    for (var i = 0; i < row.length; i++) {
      if (row[i].length > widths[i]) widths[i] = row[i].length;
    }
  }
  String line(List<String> cells) =>
      [for (var i = 0; i < widths.length; i++) cells[i].padRight(widths[i])].join('  ');
  return [line(header), widths.map((w) => '-' * w).join('  '), ...rows.map(line)].join('\n');
}
