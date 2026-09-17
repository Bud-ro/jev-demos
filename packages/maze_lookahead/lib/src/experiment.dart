import 'dart:convert';
import 'dart:io';

import 'package:jev_common/jev_common.dart';

import 'maze.dart';
import 'prompt.dart';
import 'sim.dart';

/// How many mazes to run at one size and (optionally) a budget-driven limit
/// on each "follow step 1" loop. Independently of [iterCap], every episode
/// has a hard cap of [DemoConfig.hardCapMultiplier] x the optimal move count.
class SizePlan {
  const SizePlan(this.size, {required this.trials, this.iterCap});
  final int size;
  final int trials;

  /// Sparsity limit for the preset's time budget; null means only the hard
  /// cap applies.
  final int? iterCap;

  Map<String, Object?> toJson() =>
      {'size': size, 'trials': trials, 'iterCap': iterCap};
}

class DemoConfig {
  const DemoConfig({
    required this.preset,
    required this.plan,
    required this.probeSizes,
    required this.k,
    required this.phrasing,
    required this.phrasingSizes,
    required this.phrasingTrials,
    required this.independenceSize,
    required this.independenceTrials,
    required this.independenceKs,
    required this.algo,
    required this.showTrail,
    required this.seed,
    required this.delay,
    required this.timeBudget,
    required this.outBase,
    required this.label,
  });

  final String preset;
  final List<SizePlan> plan;
  final List<int> probeSizes;

  /// Steps asked per request (upper bound; reduced per size by the probe).
  final int k;

  /// Fixed phrasing, or null to use the winner of the phrasing phase.
  final Phrasing? phrasing;
  final List<int> phrasingSizes;
  final int phrasingTrials;
  final int independenceSize;
  final int independenceTrials;
  final List<int> independenceKs;
  final String algo;
  final bool showTrail;
  final int seed;

  /// Pause between consecutive API calls (be gentle with the service).
  final Duration delay;

  /// Hard stop for the whole run.
  final Duration timeBudget;
  final String outBase;
  final String label;

  /// Every episode stops after `hardCapMultiplier * solutionLength` moves.
  static const hardCapMultiplier = 5;

  static const allSizes = [5, 10, 20, 50, 100, 200, 500, 1000];

  static DemoConfig named(String name) => switch (name) {
        'smoke' => const DemoConfig(
            preset: 'smoke',
            plan: [
              SizePlan(5, trials: 2, iterCap: 25),
              SizePlan(10, trials: 1, iterCap: 25),
            ],
            probeSizes: [5, 10, 20],
            k: 20,
            phrasing: null,
            phrasingSizes: [5],
            phrasingTrials: 1,
            independenceSize: 5,
            independenceTrials: 1,
            independenceKs: [1, 5, 20],
            algo: 'prim',
            showTrail: true,
            seed: 1,
            delay: Duration.zero,
            timeBudget: Duration(minutes: 5),
            outBase: 'results',
            label: 'smoke',
          ),
        'quick' => const DemoConfig(
            preset: 'quick',
            plan: [
              SizePlan(5, trials: 10, iterCap: 50),
              SizePlan(10, trials: 5, iterCap: 60),
              SizePlan(20, trials: 5, iterCap: 60),
              SizePlan(50, trials: 3, iterCap: 30),
              SizePlan(100, trials: 2, iterCap: 15),
              SizePlan(200, trials: 1, iterCap: 5),
            ],
            probeSizes: allSizes,
            k: 100,
            phrasing: null,
            phrasingSizes: [5, 10],
            phrasingTrials: 3,
            independenceSize: 10,
            independenceTrials: 3,
            independenceKs: [1, 10, 50, 100],
            algo: 'prim',
            showTrail: true,
            seed: 1,
            delay: Duration.zero,
            timeBudget: Duration(minutes: 12),
            outBase: 'results',
            label: 'quick',
          ),
        'full' => const DemoConfig(
            preset: 'full',
            plan: [
              SizePlan(5, trials: 10, iterCap: 60),
              SizePlan(10, trials: 10, iterCap: 100),
              SizePlan(20, trials: 10, iterCap: 120),
              SizePlan(50, trials: 10, iterCap: 60),
              SizePlan(100, trials: 5, iterCap: 30),
              SizePlan(200, trials: 3, iterCap: 10),
            ],
            probeSizes: allSizes,
            k: 100,
            phrasing: null,
            phrasingSizes: [5, 10],
            phrasingTrials: 3,
            independenceSize: 10,
            independenceTrials: 3,
            independenceKs: [1, 10, 50, 100],
            algo: 'prim',
            showTrail: true,
            seed: 1,
            delay: Duration.zero,
            timeBudget: Duration(minutes: 60),
            outBase: 'results',
            label: 'full',
          ),
        _ => throw ArgumentError('Unknown preset: $name (smoke|quick|full)'),
      };

  DemoConfig copyWith({
    List<SizePlan>? plan,
    List<int>? probeSizes,
    int? k,
    Phrasing? phrasing,
    String? algo,
    bool? showTrail,
    int? seed,
    Duration? delay,
    Duration? timeBudget,
    String? outBase,
    String? label,
  }) =>
      DemoConfig(
        preset: preset,
        plan: plan ?? this.plan,
        probeSizes: probeSizes ?? this.probeSizes,
        k: k ?? this.k,
        phrasing: phrasing ?? this.phrasing,
        phrasingSizes: phrasingSizes,
        phrasingTrials: phrasingTrials,
        independenceSize: independenceSize,
        independenceTrials: independenceTrials,
        independenceKs: independenceKs,
        algo: algo ?? this.algo,
        showTrail: showTrail ?? this.showTrail,
        seed: seed ?? this.seed,
        delay: delay ?? this.delay,
        timeBudget: timeBudget ?? this.timeBudget,
        outBase: outBase ?? this.outBase,
        label: label ?? this.label,
      );

  Map<String, Object?> toJson() => {
        'preset': preset,
        'plan': plan.map((p) => p.toJson()).toList(),
        'probeSizes': probeSizes,
        'k': k,
        'phrasing': phrasing?.name,
        'phrasingSizes': phrasingSizes,
        'phrasingTrials': phrasingTrials,
        'independenceSize': independenceSize,
        'independenceTrials': independenceTrials,
        'independenceKs': independenceKs,
        'algo': algo,
        'showTrail': showTrail,
        'seed': seed,
        'delayMs': delay.inMilliseconds,
        'timeBudgetMin': timeBudget.inMinutes,
      };
}

/// Outcome of one API call as the experiment sees it.
class AskResult {
  AskResult({required this.index, this.response, this.eval, this.error});
  final int index;
  final SystemOneResponse? response;
  final SequenceEval? eval;
  final JevApiException? error;
  bool get ok => response != null;
}

/// Runs the phases and records everything to a [RunDir].
class Experiment {
  Experiment(this.cfg, this.client, this.run, {void Function(String)? log})
      : _log = log ?? print;

  final DemoConfig cfg;
  final JevClient client;
  final RunDir run;
  final void Function(String) _log;

  final Stopwatch clock = Stopwatch()..start();
  int calls = 0;
  int inputTokens = 0;
  int outputTokens = 0;
  Duration apiTime = Duration.zero;

  /// size -> max step questions that fit (0 = infeasible).
  final Map<int, int> feasibleK = {};

  /// size -> measured latency of the probe call.
  final Map<int, Duration> probeLatency = {};

  /// size -> measured input tokens of the probe call.
  final Map<int, int> probeTokens = {};

  final Map<String, Maze> _mazes = {};
  final Set<String> _recordedMazes = {};
  bool _budgetHit = false;

  bool get overBudget => _budgetHit || clock.elapsed > cfg.timeBudget;

  String mazeId(int size, int trial) => 's$size-t$trial';

  Maze mazeFor(int size, int trial) => _mazes.putIfAbsent(
        mazeId(size, trial),
        () => Maze.generate(size,
            seed: cfg.seed + size * 1000 + trial, algo: cfg.algo),
      );

  Future<void> _recordMaze(int size, int trial) async {
    final id = mazeId(size, trial);
    if (!_recordedMazes.add(id)) return;
    final maze = mazeFor(size, trial);
    await run
        .jsonl('mazes.jsonl')
        .write({'mazeId': id, 'trial': trial, ...maze.toJson()});
  }

  int _kFor(int size) {
    final max = feasibleK[size];
    return max == null ? cfg.k : (max < cfg.k ? max : cfg.k);
  }

  /// One sequential API call with full recording. Never throws on API
  /// errors; returns [AskResult.error] instead.
  Future<AskResult> ask({
    required String phase,
    required int size,
    required int trial,
    required int iteration,
    required Maze maze,
    required Walker walker,
    required Phrasing phrasing,
    required int k,
    Map<String, Object?> extra = const {},
  }) async {
    if (cfg.delay > Duration.zero && calls > 0) {
      await Future<void>.delayed(cfg.delay);
    }
    final state = buildState(maze, walker, showTrail: cfg.showTrail);
    final questions = stepQuestions(phrasing, k);
    final bodyChars =
        jsonEncode(client.buildBody(state: state, questions: questions)).length;
    final index = calls++;
    final record = <String, Object?>{
      'index': index,
      'phase': phase,
      'mazeId': mazeId(size, trial),
      'size': size,
      'trial': trial,
      'iteration': iteration,
      'phrasing': phrasing.name,
      'k': k,
      'position': [walker.pos.r, walker.pos.c],
      'visited': walker.visited.length,
      'atGoal': walker.atGoal,
      'distToGoal': walker.distToGoal,
      'bodyChars': bodyChars,
      'mazeChars': maze.charCount,
      ...extra,
    };
    try {
      final res = await client.systemOne(state: state, questions: questions);
      inputTokens += res.usage.inputTokens;
      outputTokens += res.usage.outputTokens;
      apiTime += res.latency;
      final moves = answersToMoves(res.answers);
      final eval = evaluateSequence(maze, moves,
          from: walker.pos, visited: walker.visited);
      record.addAll({
        'status': 'ok',
        'latencyMs': res.latency.inMilliseconds,
        'attempts': res.attempts,
        'usage': res.usage.toJson(),
        'model': res.model,
        'answers': [
          for (var n = 1; n <= k; n++)
            {
              'n': n,
              'choice': res.choice(stepId(n)).choice,
              'conf': _r4(res.choice(stepId(n)).confidence),
              'probs': res
                  .choice(stepId(n))
                  .probabilities
                  .map((k, v) => MapEntry(k, _r4(v))),
            },
        ],
        'eval': {
          'validPrefix': eval.validPrefix,
          'optimalPrefix': eval.optimalPrefix,
          'firstError': eval.firstError?.name,
          'completed': eval.completed,
          'truncatedAtNone': eval.truncatedAtNone,
          'optimalRemaining': eval.optimalRemaining,
          'optimalMatch': eval.optimalMatchBits,
          'valid': eval.validBits,
        },
      });
      await run.jsonl('requests.jsonl').write(record);
      return AskResult(index: index, response: res, eval: eval);
    } on JevApiException catch (e) {
      record.addAll({
        'status': 'error',
        'httpStatus': e.status,
        'attempts': e.attempts,
        'error': e.body.length > 2000 ? e.body.substring(0, 2000) : e.body,
      });
      await run.jsonl('requests.jsonl').write(record);
      return AskResult(index: index, error: e);
    }
  }

  static double _r4(double v) => (v * 10000).round() / 10000;

  // ---------------------------------------------------------------------
  // Phase: probe
  // ---------------------------------------------------------------------

  /// Finds, per size, whether the maze fits and how many step questions can
  /// ride along. Sizes larger than the first infeasible one are skipped.
  Future<void> probe({List<int>? sizes}) async {
    final targets = (sizes ?? cfg.probeSizes)
        .where((s) => !feasibleK.containsKey(s))
        .toList()
      ..sort();
    int? firstFail;
    final phrasing = cfg.phrasing ?? Phrasing.bare;
    for (final size in targets) {
      final maze = mazeFor(size, 0);
      final dims = '${maze.width}x${maze.width}, ${maze.charCount} chars';
      if (firstFail != null && size > firstFail) {
        feasibleK[size] = 0;
        _log('[probe] size=$size ($dims): skipped, larger than first '
            'infeasible size $firstFail');
        await run.jsonl('probe.jsonl').write({
          'size': size,
          'width': maze.width,
          'chars': maze.charCount,
          'status': 'skipped',
          'reason': 'larger than first infeasible size $firstFail',
        });
        continue;
      }
      await _recordMaze(size, 0);
      var k = cfg.k;
      var attempts = 0;
      while (true) {
        attempts++;
        final r = await ask(
          phase: 'probe',
          size: size,
          trial: 0,
          iteration: 0,
          maze: maze,
          walker: Walker(maze),
          phrasing: phrasing,
          k: k,
        );
        if (r.ok) {
          final res = r.response!;
          feasibleK[size] = k;
          probeLatency[size] = res.latency;
          probeTokens[size] = res.usage.inputTokens;
          final cpt = res.usage.inputTokens == 0
              ? null
              : maze.charCount / res.usage.inputTokens;
          _log('[probe] size=$size ($dims): ok k=$k '
              'tokens=${res.usage.inputTokens} '
              'latency=${res.latency.inMilliseconds}ms'
              '${cpt == null ? '' : ' (~${cpt.toStringAsFixed(2)} maze chars/token)'}');
          await run.jsonl('probe.jsonl').write({
            'size': size,
            'width': maze.width,
            'chars': maze.charCount,
            'status': 'ok',
            'k': k,
            'probeAttempts': attempts,
            'inputTokens': res.usage.inputTokens,
            'outputTokens': res.usage.outputTokens,
            'latencyMs': res.latency.inMilliseconds,
            'mazeCharsPerToken': cpt,
          });
          break;
        }
        final e = r.error!;
        if (e.isValidation && k > 1) {
          k = k >= 4 ? k ~/ 2 : 1;
          _log('[probe] size=$size: 422, retrying with k=$k');
          continue;
        }
        feasibleK[size] = 0;
        if (e.isValidation) firstFail = size;
        _log('[probe] size=$size ($dims): infeasible, HTTP ${e.status}');
        await run.jsonl('probe.jsonl').write({
          'size': size,
          'width': maze.width,
          'chars': maze.charCount,
          'status': 'infeasible',
          'httpStatus': e.status,
          'probeAttempts': attempts,
          'error': e.body.length > 500 ? e.body.substring(0, 500) : e.body,
        });
        break;
      }
    }
  }

  // ---------------------------------------------------------------------
  // Phase: phrasing
  // ---------------------------------------------------------------------

  /// Compares question wordings on a few small mazes, one request each.
  /// Returns the phrasing to use: the forced one, else the best by mean
  /// optimal prefix (ties broken by valid prefix).
  Future<Phrasing> phrasingExperiment() async {
    await probe(sizes: cfg.phrasingSizes);
    final rows = <Map<String, Object?>>[];
    for (final size in cfg.phrasingSizes) {
      final k = _kFor(size);
      if (k == 0) continue;
      for (var t = 0; t < cfg.phrasingTrials; t++) {
        final trial = 100 + t;
        final maze = mazeFor(size, trial);
        await _recordMaze(size, trial);
        for (final phrasing in Phrasing.values) {
          if (overBudget) break;
          final r = await ask(
            phase: 'phrasing',
            size: size,
            trial: trial,
            iteration: 0,
            maze: maze,
            walker: Walker(maze),
            phrasing: phrasing,
            k: k,
          );
          if (!r.ok) {
            _log('[phrasing] size=$size trial=$t ${phrasing.name}: '
                'error ${r.error}');
            continue;
          }
          final eval = r.eval!;
          final row = {
            'size': size,
            'trial': trial,
            'phrasing': phrasing.name,
            'k': k,
            'validPrefix': eval.validPrefix,
            'optimalPrefix': eval.optimalPrefix,
            'optimalRemaining': eval.optimalRemaining,
            'completed': eval.completed,
            'firstError': eval.firstError?.name,
            'inputTokens': r.response!.usage.inputTokens,
            'latencyMs': r.response!.latency.inMilliseconds,
          };
          rows.add(row);
          await run.jsonl('phrasing.jsonl').write(row);
          _log('[phrasing] size=$size trial=$t ${phrasing.name.padRight(9)} '
              'valid=${eval.validPrefix} '
              'optimal=${eval.optimalPrefix}/${eval.optimalRemaining} '
              'tokens=${r.response!.usage.inputTokens}');
        }
      }
    }
    final summary = <String, Object?>{};
    var best = cfg.phrasing ?? Phrasing.bare;
    var bestScore = -1.0;
    for (final p in Phrasing.values) {
      final mine = rows.where((r) => r['phrasing'] == p.name).toList();
      if (mine.isEmpty) continue;
      double mean(String key) =>
          mine.map((r) => (r[key] as int).toDouble()).reduce((a, b) => a + b) /
          mine.length;
      summary[p.name] = {
        'n': mine.length,
        'meanValidPrefix': mean('validPrefix'),
        'meanOptimalPrefix': mean('optimalPrefix'),
        'meanInputTokens': mean('inputTokens'),
        'completed': mine.where((r) => r['completed'] == true).length,
      };
      final score = mean('optimalPrefix') * 1000 + mean('validPrefix');
      if (score > bestScore) {
        bestScore = score;
        best = p;
      }
    }
    final chosen = cfg.phrasing ?? best;
    await run.writeJson('phrasing_summary.json', {
      'best': best.name,
      'used': chosen.name,
      'forced': cfg.phrasing != null,
      'byPhrasing': summary,
    });
    _log('[phrasing] best=${best.name}'
        '${cfg.phrasing != null ? ' (forced: ${chosen.name})' : ''}');
    return chosen;
  }

  // ---------------------------------------------------------------------
  // Phase: independence
  // ---------------------------------------------------------------------

  /// Does asking more questions change earlier answers? Asks the same state
  /// with k=1, 10, 50, ... and compares step-1 answers and probabilities.
  Future<void> independenceCheck(Phrasing phrasing) async {
    final size = cfg.independenceSize;
    await probe(sizes: [size]);
    final kMax = _kFor(size);
    if (kMax == 0) return;
    final ks = cfg.independenceKs.where((k) => k <= kMax).toSet().toList()
      ..sort();
    final rows = <Map<String, Object?>>[];
    for (var t = 0; t < cfg.independenceTrials; t++) {
      final trial = 200 + t;
      final maze = mazeFor(size, trial);
      await _recordMaze(size, trial);
      for (final k in ks) {
        if (overBudget) break;
        final r = await ask(
          phase: 'independence',
          size: size,
          trial: trial,
          iteration: 0,
          maze: maze,
          walker: Walker(maze),
          phrasing: phrasing,
          k: k,
        );
        if (!r.ok) continue;
        final res = r.response!;
        final s1 = res.choice(stepId(1));
        final row = {
          'size': size,
          'trial': trial,
          'k': k,
          'moves': answersToMoves(res.answers).map((d) => d.label).toList(),
          'step1': s1.choice,
          'step1Probs': s1.probabilities,
          'step1Confidence': s1.confidence,
        };
        rows.add(row);
        await run.jsonl('independence.jsonl').write(row);
        _log('[independence] size=$size trial=$t k=${k.toString().padLeft(3)} '
            'step1=${s1.choice} conf=${s1.confidence.toStringAsFixed(3)}');
      }
    }
    // Per trial: does step 1 agree across every k, how much do its
    // probabilities drift, and does the shared prefix of moves agree?
    final perTrial = <Map<String, Object?>>[];
    for (var t = 0; t < cfg.independenceTrials; t++) {
      final mine = rows.where((r) => r['trial'] == 200 + t).toList();
      if (mine.length < 2) continue;
      final step1s = mine.map((r) => r['step1'] as String).toSet();
      var maxProbDiff = 0.0;
      final base = mine.first['step1Probs'] as Map<String, double>;
      for (final r in mine.skip(1)) {
        final probs = r['step1Probs'] as Map<String, double>;
        for (final e in probs.entries) {
          final diff = (e.value - (base[e.key] ?? 0)).abs();
          if (diff > maxProbDiff) maxProbDiff = diff;
        }
      }
      final minK = mine
          .map((r) => (r['moves'] as List).length)
          .reduce((a, b) => a < b ? a : b);
      var prefixAgree = true;
      for (var i = 0; i < minK && prefixAgree; i++) {
        final first = (mine.first['moves'] as List)[i];
        prefixAgree = mine.every((r) => (r['moves'] as List)[i] == first);
      }
      perTrial.add({
        'trial': 200 + t,
        'ks': mine.map((r) => r['k']).toList(),
        'step1Agree': step1s.length == 1,
        'step1MaxProbDiff': maxProbDiff,
        'sharedPrefixLength': minK,
        'sharedPrefixAgree': prefixAgree,
      });
    }
    await run.writeJson('independence_summary.json',
        {'size': size, 'ks': ks, 'trials': perTrial});
    final agree = perTrial.where((t) => t['step1Agree'] == true).length;
    _log('[independence] step-1 agreement across k: $agree/${perTrial.length} trials');
  }

  // ---------------------------------------------------------------------
  // Phase: sweep
  // ---------------------------------------------------------------------

  /// The main loop. For every maze: ask for k steps, apply step 1, repeat.
  /// Every request's full k-step prediction is recorded, so "follow all
  /// steps" analysis comes from the same data.
  Future<void> sweep(Phrasing phrasing) async {
    await probe(sizes: cfg.plan.map((p) => p.size).toList());
    for (final plan in cfg.plan) {
      final k = _kFor(plan.size);
      if (k == 0) {
        _log('[sweep] size=${plan.size}: skipped (infeasible)');
        continue;
      }
      for (var trial = 0; trial < plan.trials; trial++) {
        if (overBudget) {
          _budgetHit = true;
          _log('[sweep] time budget exhausted; skipping '
              'size=${plan.size} trial=$trial');
          await run.jsonl('episodes.jsonl').write({
            'mazeId': mazeId(plan.size, trial),
            'size': plan.size,
            'trial': trial,
            'endReason': 'budget',
            'skipped': true,
          });
          continue;
        }
        await _runEpisode(plan, trial, phrasing, k);
      }
    }
  }

  Future<void> _runEpisode(
      SizePlan plan, int trial, Phrasing phrasing, int k) async {
    final size = plan.size;
    final maze = mazeFor(size, trial);
    await _recordMaze(size, trial);
    final walker = Walker(maze);
    final distStart = walker.distToGoal;
    final hardCap = DemoConfig.hardCapMultiplier * maze.solutionLength;
    final cap = plan.iterCap == null
        ? hardCap
        : (plan.iterCap! < hardCap ? plan.iterCap! : hardCap);
    var minDist = distStart;
    var solved = false;
    var saidNoneAtGoal = false;
    int? firstErrorIndex;
    final errors = <String, int>{};
    var stalls = 0;
    var iteration = 0;
    var endReason = 'cap';
    final started = clock.elapsed;
    final id = mazeId(size, trial);

    while (true) {
      if (overBudget) {
        endReason = 'budget';
        _budgetHit = true;
        break;
      }
      if (!walker.atGoal && iteration >= cap) {
        endReason = 'cap';
        break;
      }
      final r = await ask(
        phase: 'sweep',
        size: size,
        trial: trial,
        iteration: iteration,
        maze: maze,
        walker: walker,
        phrasing: phrasing,
        k: k,
        extra: {'atGoalCheck': walker.atGoal},
      );
      if (!r.ok) {
        endReason = 'error';
        _log('[sweep] $id iter=$iteration error: ${r.error}');
        break;
      }
      final res = r.response!;
      final step1 = res.choice(stepId(1));
      final move = Dir.fromLabel(step1.choice);

      if (walker.atGoal) {
        // One extra call after arriving: does it know to stop?
        saidNoneAtGoal = move == Dir.none;
        endReason = 'goal';
        _log('[sweep] $id iter=$iteration at goal, says ${move.label} '
            '(${saidNoneAtGoal ? 'correct' : 'wrong'})');
        break;
      }

      final result = walker.apply(move);
      if (result.error != null) {
        firstErrorIndex ??= iteration;
        errors[result.error!.name] = (errors[result.error!.name] ?? 0) + 1;
      }
      if (result.distToGoal >= 0 && result.distToGoal < minDist) {
        minDist = result.distToGoal;
      }
      await run.jsonl('trajectory.jsonl').write({
        'mazeId': id,
        'size': size,
        'trial': trial,
        'iteration': iteration,
        'request': r.index,
        ...result.toJson(),
        'confidence': _r4(step1.confidence),
        'validPrefix': r.eval!.validPrefix,
        'optimalPrefix': r.eval!.optimalPrefix,
      });
      final outcome = result.error == null ? 'ok' : result.error!.name;
      _log('[sweep] $id iter=${iteration.toString().padLeft(3)} '
          '${move.label.padRight(5)} ${outcome.padRight(13)} '
          'dist=${result.distToGoal.toString().padLeft(4)} '
          'lookahead=${r.eval!.optimalPrefix.toString().padLeft(3)} '
          'conf=${step1.confidence.toStringAsFixed(2)} '
          '${res.latency.inMilliseconds}ms ${res.usage.inputTokens}tok');
      iteration++;

      if (result.atGoal) {
        solved = true;
        continue; // one more call to check for NONE
      }
      if (result.after == result.before) {
        stalls++;
        if (stalls >= 2) {
          // Same state again would get the same answer; stop looping.
          endReason = 'stall';
          break;
        }
      } else {
        stalls = 0;
      }
    }

    final distEnd = walker.distToGoal;
    final episode = {
      'mazeId': id,
      'size': size,
      'trial': trial,
      'k': k,
      'phrasing': phrasing.name,
      'iterCap': plan.iterCap,
      'hardCap': hardCap,
      'effectiveCap': cap,
      'solutionLength': maze.solutionLength,
      'iterations': iteration,
      'solved': solved,
      'saidNoneAtGoal': saidNoneAtGoal,
      'endReason': endReason,
      'firstErrorIndex': firstErrorIndex,
      'movesBeforeFirstError': firstErrorIndex ?? iteration,
      'errors': errors,
      'errorCount': errors.values.fold<int>(0, (a, b) => a + b),
      'distStart': distStart,
      'distEnd': distEnd,
      'minDist': minDist,
      'progress': distStart == 0 ? 1.0 : (distStart - minDist) / distStart,
      'elapsedMs': (clock.elapsed - started).inMilliseconds,
    };
    await run.jsonl('episodes.jsonl').write(episode);
    _log('[sweep] $id done: ${solved ? 'SOLVED' : 'unsolved'} in '
        '$iteration iters, end=$endReason, '
        'clean=${episode['movesBeforeFirstError']}, '
        'progress=${(episode['progress'] as double).toStringAsFixed(2)}');
  }

  // ---------------------------------------------------------------------
  // Run metadata
  // ---------------------------------------------------------------------

  Future<void> writeRunMeta({
    required DateTime startedAt,
    required Phrasing? phrasing,
    required bool mock,
    required List<String> phases,
  }) =>
      run.writeJson('run.json', {
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': DateTime.now().toIso8601String(),
        'elapsedSec': clock.elapsed.inSeconds,
        'apiTimeSec': apiTime.inMilliseconds / 1000,
        'calls': calls,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'mock': mock,
        'phases': phases,
        'phrasingUsed': phrasing?.name,
        'feasibleK': feasibleK.map((k, v) => MapEntry('$k', v)),
        'probeLatencyMs':
            probeLatency.map((k, v) => MapEntry('$k', v.inMilliseconds)),
        'probeInputTokens': probeTokens.map((k, v) => MapEntry('$k', v)),
        'budgetHit': _budgetHit,
        'config': cfg.toJson(),
        'hostname': Platform.localHostname,
      });
}
