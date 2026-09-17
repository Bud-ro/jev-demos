import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:jev_common/jev_common.dart';
import 'package:maze_graph/maze_graph.dart';

const _usage = '''
maze_graph: the pahndev Type-Safe-Maze-Demo methodology, reproduced and scaled.

Usage: dart run maze_graph [options] <command> [args]

Commands
  run            run the sweep for the preset (default command)
  plan           napkin math: calls, time and cost, no API calls
  show           print a maze, the state JSON and the questions for --n
  analyze <dir>  re-run the analysis on a results directory

Presets: theirs (5x5, k=1, cap 80, exactly the original), quick (5..50, k=10), smoke.
Every API call is made sequentially.
''';

void main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('preset', abbr: 'p', defaultsTo: 'theirs', allowed: ['smoke', 'theirs', 'quick'])
    ..addOption('sizes', help: 'Override sizes, e.g. 5,10,20 (uses preset trials/caps or defaults).')
    ..addOption('trials')
    ..addOption('cap', help: 'Sparsity cap on moves per episode (hard cap 5x optimal always applies).')
    ..addOption('k', help: 'Questions per request: 1 = original, more = lookahead directions.')
    ..addOption('observation', allowed: ['partial', 'full'], help: 'What the model sees (default from preset).')
    ..addOption('extra', help: 'Extra-passage probability (0.12 original, 0 = perfect maze).')
    ..addOption('seed')
    ..addOption('delay-ms')
    ..addOption('budget-min')
    ..addOption('max-cost-usd', defaultsTo: '1.00')
    ..addOption('out')
    ..addOption('label')
    ..addOption('n', defaultsTo: '5', help: 'Maze size for "show".')
    ..addFlag('mock', help: 'Offline oracle instead of the API.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(_usage);
    exit(64);
  }
  if (args['help'] as bool) {
    print(_usage);
    print(parser.usage);
    return;
  }
  final command = args.rest.isEmpty ? 'run' : args.rest.first;
  final cfg = _configFrom(args);
  switch (command) {
    case 'show':
      _show(cfg, int.parse(args['n'] as String));
    case 'plan':
      final e = estimatePlan(cfg, JevPricing.fromEnv(loadEnv()));
      print(_table(['size', 'optimal', 'trials', 'cap', 'worstCalls', 'inputTok', 'worstTime', 'worstCost'], e.rows));
      print(estimateLine(cfg, e));
    case 'analyze':
      print((await analyzeRun(Directory(args.rest[1]))).report);
    case 'run':
      await _run(cfg, args);
    default:
      stderr.writeln('Unknown command: $command');
      exit(64);
  }
}

GraphConfig _configFrom(ArgResults args) {
  var cfg = GraphConfig.named(args['preset'] as String);
  cfg = cfg.copyWith(outBase: args['out'] as String? ?? _defaultOut());
  if (args['k'] != null) cfg = cfg.copyWith(k: int.parse(args['k'] as String));
  if (args['observation'] != null) cfg = cfg.copyWith(observation: Observation.values.byName(args['observation'] as String));
  if (args['extra'] != null) cfg = cfg.copyWith(extra: double.parse(args['extra'] as String));
  if (args['seed'] != null) cfg = cfg.copyWith(seed: int.parse(args['seed'] as String));
  if (args['delay-ms'] != null) cfg = cfg.copyWith(delay: Duration(milliseconds: int.parse(args['delay-ms'] as String)));
  if (args['budget-min'] != null) cfg = cfg.copyWith(timeBudget: Duration(minutes: int.parse(args['budget-min'] as String)));
  if (args['label'] != null) cfg = cfg.copyWith(label: args['label'] as String);
  var plan = cfg.plan;
  if (args['sizes'] != null) {
    plan = [
      for (final s in (args['sizes'] as String).split(',').map((s) => int.parse(s.trim())))
        plan.where((p) => p.n == s).firstOrNull ?? SizePlan(s, trials: 3, cap: 150),
    ];
  }
  if (args['trials'] != null) {
    plan = [for (final p in plan) SizePlan(p.n, trials: int.parse(args['trials'] as String), cap: p.cap)];
  }
  if (args['cap'] != null) {
    plan = [for (final p in plan) SizePlan(p.n, trials: p.trials, cap: int.parse(args['cap'] as String))];
  }
  return cfg.copyWith(plan: plan);
}

String _defaultOut() => Directory('${Directory.current.path}/packages/maze_graph').existsSync()
    ? 'packages/maze_graph/results'
    : 'results';

void _show(GraphConfig cfg, int n) {
  final m = CellMaze.generate(n, seed: cfg.seed + n * 1000, extra: cfg.extra);
  print('n=$n cells=${m.cells} optimalMoves=${m.optimalMoves} hardCap=${GraphConfig.hardCapMultiplier * m.optimalMoves}');
  print(m.render(at: m.start).join('\n'));
  final history = [m.start];
  final state = buildGraphState(m, history, observation: cfg.observation);
  final questions = buildGraphQuestions(m, history, k: cfg.k);
  final body = {'state': state, 'questions': questions.map((k, q) => MapEntry(k, q.toJson()))};
  print(const JsonEncoder.withIndent('  ').convert(body));
  print('(${jsonEncode(body).length} JSON chars)');
  for (final policy in ['random', 'unvisited']) {
    final b = simulateBaseline(m, policy: policy, cap: 80, runs: 2000);
    print('$policy baseline under cap 80: solves ${(b.solveRate * 100).toStringAsFixed(0)}%, '
        'mean moves ${b.meanMovesSolved?.toStringAsFixed(0)}');
  }
}

Future<void> _run(GraphConfig cfg, ArgResults args) async {
  final mock = args['mock'] as bool;
  final env = loadEnv();
  final pricing = mock ? const JevPricing() : JevPricing.fromEnv(env);
  final estimate = estimatePlan(cfg, pricing);
  print(estimateLine(cfg, estimate));
  final maxCost = double.parse(args['max-cost-usd'] as String);
  if (!mock && estimate.cost > maxCost) {
    stderr.writeln('Refusing to start: worst-case ${JevPricing.usd(estimate.cost)} exceeds --max-cost-usd ${JevPricing.usd(maxCost)}.');
    exit(2);
  }
  final client = mock
      ? JevClient(apiKey: 'mock', httpClient: MockGraphJev(seed: cfg.seed).client())
      : JevClient.fromEnv(env);
  final run = RunDir.create(cfg.outBase, '${cfg.label}-${cfg.observation.name}-k${cfg.k}${mock ? '-mock' : ''}');
  final logFile = run.file('log.txt').openWrite();
  void log(String line) {
    print(line);
    logFile.writeln(line);
  }

  log('run dir: ${run.path}');
  log('preset=${cfg.preset} observation=${cfg.observation.name} k=${cfg.k} extra=${cfg.extra} mock=$mock');
  final startedAt = DateTime.now();
  final exp = Experiment(cfg, client, run, pricing: pricing, log: log);
  try {
    await exp.sweep();
  } finally {
    await exp.writeRunMeta(startedAt: startedAt, mock: mock);
    await run.close();
    client.close();
    log('done: ${exp.calls} calls, ${exp.inputTokens} input tokens, ${exp.clock.elapsed.inSeconds}s elapsed, '
        'spend ${JevPricing.usd(exp.costUsd)}${mock ? ' (mock)' : ''}');
    await logFile.close();
  }
  print('');
  print((await analyzeRun(run.dir)).report);
  print('summary: ${run.file('summary.json').path}');
}

String _table(List<String> header, List<List<String>> rows) {
  final widths = List<int>.generate(header.length, (i) => header[i].length);
  for (final row in rows) {
    for (var i = 0; i < row.length; i++) {
      if (row[i].length > widths[i]) widths[i] = row[i].length;
    }
  }
  String line(List<String> cells) => [for (var i = 0; i < widths.length; i++) cells[i].padRight(widths[i])].join('  ');
  return [line(header), widths.map((w) => '-' * w).join('  '), ...rows.map(line)].join('\n');
}
