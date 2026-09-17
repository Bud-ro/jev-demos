import 'dart:convert';
import 'dart:io';

import 'package:jev_common/jev_common.dart';

import 'cell_maze.dart';
import 'prompt.dart';

class SizePlan {
  const SizePlan(this.n, {required this.trials, required this.cap});
  final int n;
  final int trials;

  /// Sparsity cap on moves per episode; the hard cap of
  /// [GraphConfig.hardCapMultiplier] x optimal also applies.
  final int cap;
  Map<String, Object?> toJson() => {'n': n, 'trials': trials, 'cap': cap};
}

class GraphConfig {
  const GraphConfig({
    required this.preset,
    required this.plan,
    required this.k,
    required this.observation,
    required this.extra,
    required this.seed,
    required this.delay,
    required this.timeBudget,
    required this.outBase,
    required this.label,
    required this.baselineRuns,
  });

  final String preset;
  final List<SizePlan> plan;

  /// Questions per request: 1 is the original demo; more adds lookahead.
  final int k;
  final Observation observation;

  /// Probability of opening each extra passage (0.12 in the original).
  final double extra;
  final int seed;
  final Duration delay;
  final Duration timeBudget;
  final String outBase;
  final String label;
  final int baselineRuns;

  static const hardCapMultiplier = 5;

  static GraphConfig named(String name) => switch (name) {
        'smoke' => const GraphConfig(
            preset: 'smoke',
            plan: [SizePlan(5, trials: 2, cap: 40)],
            k: 3,
            observation: Observation.partial,
            extra: 0.12,
            seed: 1,
            delay: Duration.zero,
            timeBudget: Duration(minutes: 3),
            outBase: 'results',
            label: 'smoke',
            baselineRuns: 500,
          ),
        // The original demo: 5x5, one question, 80-move cap.
        'theirs' => const GraphConfig(
            preset: 'theirs',
            plan: [SizePlan(5, trials: 10, cap: 80)],
            k: 1,
            observation: Observation.partial,
            extra: 0.12,
            seed: 1,
            delay: Duration.zero,
            timeBudget: Duration(minutes: 10),
            outBase: 'results',
            label: 'theirs',
            baselineRuns: 2000,
          ),
        'quick' => const GraphConfig(
            preset: 'quick',
            plan: [
              SizePlan(5, trials: 10, cap: 80),
              SizePlan(10, trials: 5, cap: 150),
              SizePlan(20, trials: 3, cap: 200),
              SizePlan(50, trials: 2, cap: 150),
            ],
            k: 10,
            observation: Observation.partial,
            extra: 0.12,
            seed: 1,
            delay: Duration.zero,
            timeBudget: Duration(minutes: 15),
            outBase: 'results',
            label: 'quick',
            baselineRuns: 2000,
          ),
        _ => throw ArgumentError('Unknown preset: $name (smoke|theirs|quick)'),
      };

  GraphConfig copyWith({
    List<SizePlan>? plan,
    int? k,
    Observation? observation,
    double? extra,
    int? seed,
    Duration? delay,
    Duration? timeBudget,
    String? outBase,
    String? label,
  }) =>
      GraphConfig(
        preset: preset,
        plan: plan ?? this.plan,
        k: k ?? this.k,
        observation: observation ?? this.observation,
        extra: extra ?? this.extra,
        seed: seed ?? this.seed,
        delay: delay ?? this.delay,
        timeBudget: timeBudget ?? this.timeBudget,
        outBase: outBase ?? this.outBase,
        label: label ?? this.label,
        baselineRuns: baselineRuns,
      );

  Map<String, Object?> toJson() => {
        'preset': preset,
        'plan': plan.map((p) => p.toJson()).toList(),
        'k': k,
        'observation': observation.name,
        'extra': extra,
        'seed': seed,
        'delayMs': delay.inMilliseconds,
        'timeBudgetMin': timeBudget.inMinutes,
        'baselineRuns': baselineRuns,
      };
}

/// Rough input tokens per call before any measurement.
int estimateTokens(GraphConfig cfg, int n, int cap) {
  final cells = n * n;
  final revealed = cfg.observation == Observation.full ? cells : (cap < cells ? cap : cells);
  return 120 + revealed * 30 + 90 + (cfg.k - 1) * 45;
}

class PlanEstimate {
  const PlanEstimate(this.rows, this.calls, this.tokens, this.seconds, this.cost);
  final List<List<String>> rows;
  final int calls;
  final int tokens;
  final double seconds;
  final double cost;
}

PlanEstimate estimatePlan(GraphConfig cfg, JevPricing pricing,
    {Map<int, int> measuredTokens = const {}, Map<int, int> measuredLatencyMs = const {}}) {
  var calls = 0, tokens = 0;
  var seconds = 0.0;
  final rows = <List<String>>[];
  for (final p in cfg.plan) {
    final m = CellMaze.generate(p.n, seed: cfg.seed + p.n * 1000, extra: cfg.extra);
    final hard = GraphConfig.hardCapMultiplier * m.optimalMoves;
    final cap = p.cap < hard ? p.cap : hard;
    final tok = measuredTokens[p.n] ?? estimateTokens(cfg, p.n, cap);
    final lat = measuredLatencyMs[p.n] ?? (300 + tok ~/ 40);
    final over = tok > 32000;
    final c = p.trials * cap;
    if (!over) {
      calls += c;
      tokens += c * tok;
      seconds += c * lat / 1000;
    }
    rows.add([
      '${p.n}x${p.n}',
      '${m.optimalMoves}',
      '${p.trials}',
      '$cap',
      '$c',
      '~$tok${over ? ' (over)' : ''}',
      over ? 'skip' : '${(c * lat / 60000).toStringAsFixed(1)} min',
      over ? 'skip' : JevPricing.usd(pricing.cost(inputTokens: c * tok)),
    ]);
  }
  return PlanEstimate(rows, calls, tokens, seconds, pricing.cost(inputTokens: tokens));
}

String estimateLine(GraphConfig cfg, PlanEstimate e) {
  final capped = e.seconds > cfg.timeBudget.inSeconds;
  return 'ESTIMATE: up to ${e.calls} calls, ${(e.tokens / 1e6).toStringAsFixed(2)}M input tokens; '
      'time ${(e.seconds / 60).toStringAsFixed(1)} min worst case'
      '${capped ? ', hard-stopped at ${cfg.timeBudget.inMinutes} min' : ''}; '
      'cost ${JevPricing.usd(e.cost)} worst case';
}

class Experiment {
  Experiment(this.cfg, this.client, this.run, {this.pricing = const JevPricing(), void Function(String)? log})
      : _log = log ?? print;

  final GraphConfig cfg;
  final JevClient client;
  final RunDir run;
  final JevPricing pricing;
  final void Function(String) _log;
  final Stopwatch clock = Stopwatch()..start();
  int calls = 0, inputTokens = 0, outputTokens = 0;
  Duration apiTime = Duration.zero;
  bool budgetHit = false;
  final Map<int, int> measuredTokens = {};
  final Map<int, int> measuredLatencyMs = {};

  double get costUsd => pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens);
  bool get overBudget => budgetHit || clock.elapsed > cfg.timeBudget;

  String mazeId(int n, int trial) => 'n$n-t$trial';
  CellMaze mazeFor(int n, int trial) =>
      CellMaze.generate(n, seed: cfg.seed + n * 1000 + trial, extra: cfg.extra);

  Future<void> sweep() async {
    for (final plan in cfg.plan) {
      var infeasible = false;
      for (var trial = 0; trial < plan.trials && !infeasible; trial++) {
        if (overBudget) {
          budgetHit = true;
          _log('[sweep] time budget exhausted; skipping ${mazeId(plan.n, trial)}');
          await run.jsonl('episodes.jsonl').write({
            'mazeId': mazeId(plan.n, trial), 'n': plan.n, 'trial': trial,
            'endReason': 'budget', 'skipped': true,
          });
          continue;
        }
        infeasible = await _episode(plan, trial);
      }
    }
  }

  /// Returns true when the size is infeasible (422) so the rest is skipped.
  Future<bool> _episode(SizePlan plan, int trial) async {
    final n = plan.n;
    final m = mazeFor(n, trial);
    final id = mazeId(n, trial);
    final hard = GraphConfig.hardCapMultiplier * m.optimalMoves;
    final cap = plan.cap < hard ? plan.cap : hard;
    final baselines = [
      for (final policy in baselinePolicies)
        simulateBaseline(m, policy: policy, cap: cap, runs: cfg.baselineRuns, seed: cfg.seed),
    ];
    await run.jsonl('mazes.jsonl').write({
      'mazeId': id, 'trial': trial, ...m.toJson(), 'cap': cap,
      'baselines': baselines.map((b) => b.toJson()).toList(),
    });

    final history = [m.start];
    var optimalHops = 0, revisits = 0, moves = 0;
    var endReason = 'cap';
    final started = clock.elapsed;
    while (true) {
      if (history.last == m.goal) {
        endReason = 'goal';
        break;
      }
      if (moves >= cap) {
        endReason = 'cap';
        break;
      }
      if (overBudget) {
        endReason = 'budget';
        budgetHit = true;
        break;
      }
      if (cfg.delay > Duration.zero && calls > 0) await Future<void>.delayed(cfg.delay);
      final current = history.last;
      final state = buildGraphState(m, history, observation: cfg.observation);
      final questions = buildGraphQuestions(m, history, k: cfg.k);
      final index = calls++;
      final record = <String, Object?>{
        'index': index, 'mazeId': id, 'n': n, 'trial': trial, 'move': moves,
        'current': current, 'distToGoal': m.distance(current),
        'discovered': history.toSet().length, 'legalExits': m.exits[current].length,
        'k': cfg.k, 'observation': cfg.observation.name,
        'bodyChars': jsonEncode(client.buildBody(state: state, questions: questions)).length,
      };
      SystemOneResponse res;
      try {
        res = await client.systemOne(state: state, questions: questions);
      } on JevApiException catch (e) {
        record.addAll({'status': 'error', 'httpStatus': e.status, 'error': e.body.length > 1000 ? e.body.substring(0, 1000) : e.body});
        await run.jsonl('requests.jsonl').write(record);
        _log('[sweep] $id move=$moves error HTTP ${e.status}: ${e.body.length > 200 ? e.body.substring(0, 200) : e.body}');
        endReason = e.isValidation ? 'infeasible' : 'error';
        break;
      }
      inputTokens += res.usage.inputTokens;
      outputTokens += res.usage.outputTokens;
      apiTime += res.latency;
      measuredTokens.putIfAbsent(n, () => res.usage.inputTokens);
      measuredLatencyMs.putIfAbsent(n, () => res.latency.inMilliseconds);

      final move = res.choice('move');
      final next = chosenCell(move);
      final later = laterDirections(res.answers);
      final eval = evaluateLookahead(m, current, next, later);
      final legal = m.exits[current].contains(next);
      final best = m.bestHops(current).contains(next);
      final revisit = history.contains(next);
      record.addAll({
        'status': 'ok',
        'latencyMs': res.latency.inMilliseconds,
        'usage': res.usage.toJson(),
        'chosen': next,
        'legal': legal,
        'optimalHop': best,
        'revisit': revisit,
        'confidence': move.confidence,
        'probabilities': move.probabilities,
        'later': later.map((d) => d.label).toList(),
        'laterConfidence': [for (var i = 2; i <= cfg.k; i++) res.choice('step$i').confidence],
        'eval': eval.toJson(),
      });
      await run.jsonl('requests.jsonl').write(record);
      if (!legal) {
        endReason = 'illegal';
        _log('[sweep] $id move=$moves illegal choice $next');
        break;
      }
      history.add(next);
      moves++;
      if (best) optimalHops++;
      if (revisit) revisits++;
      await run.jsonl('trajectory.jsonl').write({
        'mazeId': id, 'n': n, 'trial': trial, 'move': moves, 'from': current, 'to': next,
        'dist': m.distance(next), 'optimalHop': best, 'revisit': revisit,
        'confidence': move.confidence, 'lookaheadOptimal': eval.optimalPrefix, 'request': index,
      });
      final kind = best ? 'best' : (revisit ? 'revisit' : 'detour');
      _log('[sweep] $id move=${moves.toString().padLeft(3)} '
          '${'$current->$next'.padRight(12)} ${kind.padRight(7)} '
          'dist=${m.distance(next).toString().padLeft(4)} '
          'conf=${move.confidence.toStringAsFixed(2)} '
          'lookahead=${eval.optimalPrefix} ${res.latency.inMilliseconds}ms ${res.usage.inputTokens}tok');
    }
    final solved = history.last == m.goal;
    final episode = {
      'mazeId': id, 'n': n, 'trial': trial, 'k': cfg.k, 'observation': cfg.observation.name,
      'cap': cap, 'optimalMoves': m.optimalMoves, 'moves': moves, 'solved': solved,
      'endReason': endReason, 'ratio': solved ? moves / m.optimalMoves : null,
      'optimalHops': optimalHops, 'optimalHopRate': moves == 0 ? null : optimalHops / moves,
      'revisits': revisits, 'uniqueCells': history.toSet().length,
      'distEnd': m.distance(history.last),
      'progress': 1 - m.distance(history.last) / m.optimalMoves,
      'history': history,
      'baselines': baselines.map((b) => b.toJson()).toList(),
      'elapsedMs': (clock.elapsed - started).inMilliseconds,
    };
    await run.jsonl('episodes.jsonl').write(episode);
    _log('[sweep] $id done: ${solved ? 'SOLVED' : 'unsolved'} in $moves moves '
        '(optimal ${m.optimalMoves}, cap $cap), end=$endReason, '
        'baselines: ${baselines.map((b) => '${b.policy} ${(b.solveRate * 100).round()}%').join(', ')}');
    return endReason == 'infeasible';
  }

  Future<void> writeRunMeta({required DateTime startedAt, required bool mock}) => run.writeJson('run.json', {
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': DateTime.now().toIso8601String(),
        'elapsedSec': clock.elapsed.inSeconds,
        'apiTimeSec': apiTime.inMilliseconds / 1000,
        'calls': calls,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'costUsd': costUsd,
        'pricing': pricing.toJson(),
        'mock': mock,
        'budgetHit': budgetHit,
        'measuredTokens': measuredTokens.map((k, v) => MapEntry('$k', v)),
        'measuredLatencyMs': measuredLatencyMs.map((k, v) => MapEntry('$k', v)),
        'config': cfg.toJson(),
        'hostname': Platform.localHostname,
      });
}
