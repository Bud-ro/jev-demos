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
  ablate         run the sweep once per state variant and compare (small mazes)
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
    ..addOption('state', allowed: StateOptions.variants.keys.toList(),
        defaultsTo: 'baseline', help: 'Which pieces of context go into the state.')
    ..addFlag('trail', defaultsTo: true, help: 'Draw visited cells as "." in the maze.')
    ..addOption('seed', help: 'Base RNG seed for maze generation.')
    ..addOption('delay-ms', help: 'Pause between API calls.')
    ..addOption('budget-min', help: 'Hard time budget for the run in minutes.')
    ..addOption('out', help: 'Results base directory (default: <package>/results).')
    ..addOption('label', help: 'Suffix for the run directory name.')
    ..addOption('max-cost-usd', defaultsTo: '1.00',
        help: 'Refuse to start a real run whose worst-case estimate exceeds this.')
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
    case 'ablate':
      await _ablate(cfg, args);
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
  cfg = cfg.copyWith(stateVariant: args['state'] as String);
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
  final state = buildState(maze, walker,
      options: StateOptions.named(cfg.stateVariant).copyWith(trail: cfg.showTrail));
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
  final pricing = JevPricing.fromEnv(loadEnv());
  Map<String, dynamic>? meta;
  if (measuredFrom != null) {
    final f = File('${measuredFrom.path}/run.json');
    if (f.existsSync()) meta = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  }
  Map<int, T> parse<T>(String key, T Function(num) conv) => {
        for (final e in ((meta?[key] as Map<String, dynamic>?) ?? const {}).entries)
          int.parse(e.key): conv(e.value as num),
      };
  final estimate = estimatePlan(
    cfg,
    pricing: pricing,
    feasibleK: parse('feasibleK', (v) => v.toInt()),
    probeTokens: parse('probeInputTokens', (v) => v.toInt()),
    probeLatency: parse('probeLatencyMs', (v) => Duration(milliseconds: v.toInt())),
  );
  if (meta != null) print('(using measurements from ${measuredFrom!.path})\n');
  print(formatEstimate(estimate));
}

/// Runs the sweep once per state variant on a small plan and prints a
/// side-by-side comparison. Defaults: size 5, 3 mazes, cap 30, k 25.
Future<void> _ablate(DemoConfig base, ArgResults args) async {
  var cfg = base;
  if (args['sizes'] == null) cfg = cfg.copyWith(plan: [const SizePlan(5, trials: 3, iterCap: 30)]);
  if (args['trials'] == null) {
    cfg = cfg.copyWith(plan: [for (final p in cfg.plan) SizePlan(p.size, trials: 3, iterCap: p.iterCap)]);
  }
  if (args['iter-cap'] == null) {
    cfg = cfg.copyWith(plan: [for (final p in cfg.plan) SizePlan(p.size, trials: p.trials, iterCap: 30)]);
  }
  if (args['k'] == null) cfg = cfg.copyWith(k: 25);
  if (args['phrasing'] == null) cfg = cfg.copyWith(phrasing: Phrasing.bare);

  final rows = <List<String>>[];
  for (final variant in StateOptions.variants.keys) {
    print('');
    print('===== state variant: $variant');
    final dir = await _runPhases(
      cfg.copyWith(stateVariant: variant, label: 'ablate-$variant'),
      args,
      'sweep',
      quiet: true,
    );
    final summary = jsonDecode(File('${dir.path}/summary.json').readAsStringSync())
        as Map<String, dynamic>;
    final meta = summary['meta'] as Map<String, dynamic>;
    var solved = 0, trials = 0;
    var clean = 0.0, valid = 0.0, optimal = 0.0, n = 0;
    final errors = <String, int>{};
    for (final e in (summary['perSize'] as Map<String, dynamic>).values) {
      final a = e['modeA'] as Map<String, dynamic>;
      final b = e['modeB'] as Map<String, dynamic>;
      solved += a['solved'] as int;
      trials += a['trials'] as int;
      clean += ((a['meanMovesBeforeFirstError'] as num?) ?? 0) * (a['trials'] as int);
      valid += ((b['meanValidPrefix'] as num?) ?? 0) * (b['requestsFromStart'] as int);
      optimal += ((b['meanOptimalPrefix'] as num?) ?? 0) * (b['requestsFromStart'] as int);
      n += b['requestsFromStart'] as int;
      for (final err in (a['errors'] as Map<String, dynamic>).entries) {
        errors[err.key] = (errors[err.key] ?? 0) + (err.value as int);
      }
    }
    rows.add([
      variant,
      '$solved/$trials',
      trials == 0 ? '' : (clean / trials).toStringAsFixed(1),
      n == 0 ? '' : (valid / n).toStringAsFixed(1),
      n == 0 ? '' : (optimal / n).toStringAsFixed(1),
      errors.entries.map((e) => '${e.key}=${e.value}').join(' '),
      '${meta['inputTokens']}',
      JevPricing.usd((meta['costUsd'] as num).toDouble()),
    ]);
  }
  print('');
  print('State variant comparison (Mode A loop, sizes ${cfg.plan.map((p) => p.size).join(',')}, '
      '${cfg.plan.first.trials} mazes each, cap ${cfg.plan.first.iterCap}, k=${cfg.k})');
  print(table(
    ['variant', 'solved', 'cleanMoves', 'validPrefix', 'optimalPrefix', 'errors', 'inputTok', 'cost'],
    rows,
  ));
  print('  cleanMoves = loop moves before the first error; validPrefix/optimalPrefix =');
  print('  one-shot plan from the start position (Mode B).');
}

Future<Directory> _runPhases(DemoConfig cfg, ArgResults args, String command,
    {bool quiet = false}) async {
  final mock = args['mock'] as bool;
  final startedAt = DateTime.now();
  final env = loadEnv();
  final pricing = mock ? const JevPricing() : JevPricing.fromEnv(env);

  // Cost and time check before the first call.
  final estimate = estimatePlan(cfg, pricing: pricing);
  print(summaryLine(estimate));
  final maxCost = double.parse(args['max-cost-usd'] as String);
  if (!mock && estimate.worstCostUsd > maxCost) {
    stderr.writeln('Refusing to start: worst-case cost ${JevPricing.usd(estimate.worstCostUsd)} '
        'exceeds --max-cost-usd ${JevPricing.usd(maxCost)}. Shrink the plan '
        '(--sizes, --trials, --iter-cap, --k) or raise the limit.');
    exit(2);
  }
  if (mock) print('(mock run: no real spend; estimate shown for reference)');

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
    client = JevClient.fromEnv(env);
  }

  final label = '${cfg.label}${mock ? '-mock' : ''}${command == 'all' ? '' : '-$command'}';
  final run = RunDir.create(cfg.outBase, label);
  final logFile = run.file('log.txt').openWrite();
  void log(String line) {
    if (!quiet || !line.startsWith('[sweep] ') || line.contains(' done: ')) print(line);
    logFile.writeln(line);
  }

  log('run dir: ${run.path}');
  log('preset=${cfg.preset} k=${cfg.k} algo=${cfg.algo} trail=${cfg.showTrail} '
      'mock=$mock budget=${cfg.timeBudget.inMinutes}min');
  final exp = Experiment(cfg, client, run, log: log, pricing: pricing);
  final phases = <String>[];
  Phrasing? phrasing = cfg.phrasing;

  // After the probe we know real token counts and latencies; re-estimate.
  void refine() {
    final refined = estimatePlan(
      cfg,
      pricing: pricing,
      feasibleK: exp.feasibleK,
      probeTokens: exp.probeTokens,
      probeLatency: exp.probeLatency,
    );
    log('REFINED ${summaryLine(refined)}');
    log('spent so far: ${JevPricing.usd(exp.costUsd)} over ${exp.calls} calls');
  }

  try {
    switch (command) {
      case 'probe':
        phases.add('probe');
        await exp.probe();
        refine();
      case 'phrasing':
        phases.add('phrasing');
        phrasing = await exp.phrasingExperiment();
      case 'independence':
        phases.add('independence');
        await exp.independenceCheck(phrasing ?? Phrasing.bare);
      case 'sweep':
        phases.add('sweep');
        await exp.probe(sizes: cfg.plan.map((p) => p.size).toList());
        refine();
        await exp.sweep(phrasing ?? Phrasing.bare);
      case 'all':
        phases.add('probe');
        await exp.probe();
        refine();
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
        '(${(exp.apiTime.inMilliseconds / 1000).toStringAsFixed(1)}s in API), '
        'spend ${JevPricing.usd(exp.costUsd)}${mock ? ' (mock, not billed)' : ''}');
    await logFile.close();
  }

  final analysis = await analyzeRun(run.dir);
  if (!quiet) {
    print('');
    print(analysis.report);
  }
  print('summary: ${run.file('summary.json').path}');
  return run.dir;
}
