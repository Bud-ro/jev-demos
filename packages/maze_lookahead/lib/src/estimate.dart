import 'package:jev_common/jev_common.dart';

import 'experiment.dart';
import 'maze.dart';
import 'prompt.dart';

/// Rough input-token model for one request until the probe measures it:
/// maze characters at [charsPerToken], a fixed overhead for the rules and
/// legend, and a per-question cost.
const charsPerToken = 2.5;
const stateOverheadTokens = 450;
const tokensPerQuestion = 12;

/// Latency guesses per size in milliseconds until a probe measures them.
const latencyGuessMs = {
  5: 300, 10: 350, 20: 500, 50: 1000, 100: 2000, 200: 4000, 500: 6000, 1000: 8000,
};

/// Requests above this many input tokens are assumed to be rejected.
const tokenBudget = 32000;

int estimateInputTokens(Maze maze, int k) =>
    (maze.charCount / charsPerToken).round() + stateOverheadTokens + k * tokensPerQuestion;

class SizeEstimate {
  const SizeEstimate({
    required this.size,
    required this.width,
    required this.chars,
    required this.inputTokens,
    required this.measured,
    required this.optimal,
    required this.trials,
    required this.cap,
    required this.worstCalls,
    required this.latencyMs,
    required this.infeasible,
  });

  final int size;
  final int width;
  final int chars;
  final int inputTokens;

  /// Whether tokens/latency come from a probe rather than the guess model.
  final bool measured;
  final int optimal;
  final int trials;
  final int cap;
  final int worstCalls;
  final int latencyMs;
  final bool infeasible;

  int get worstTokens => infeasible ? 0 : worstCalls * inputTokens;
  double get worstSeconds => infeasible ? 0 : worstCalls * latencyMs / 1000;
}

class PlanEstimate {
  const PlanEstimate({
    required this.cfg,
    required this.pricing,
    required this.rows,
    required this.overheadCalls,
    required this.overheadTokens,
    required this.overheadSeconds,
  });

  final DemoConfig cfg;
  final JevPricing pricing;
  final List<SizeEstimate> rows;
  final int overheadCalls;
  final int overheadTokens;
  final double overheadSeconds;

  int get sweepCalls => rows.fold(0, (a, r) => a + (r.infeasible ? 0 : r.worstCalls));
  int get sweepTokens => rows.fold(0, (a, r) => a + r.worstTokens);
  double get sweepSeconds => rows.fold(0.0, (a, r) => a + r.worstSeconds);

  int get totalCalls => sweepCalls + overheadCalls;
  int get totalTokens => sweepTokens + overheadTokens;
  double get worstSeconds => sweepSeconds + overheadSeconds;

  /// The time budget hard-stops the run, so wall-clock cannot exceed it.
  double get cappedSeconds => worstSeconds < cfg.timeBudget.inSeconds
      ? worstSeconds
      : cfg.timeBudget.inSeconds.toDouble();

  double get worstCostUsd => pricing.cost(inputTokens: totalTokens);

  /// Cost if the run is cut off by the time budget (tokens scale with time).
  double get cappedCostUsd =>
      worstSeconds == 0 ? 0 : worstCostUsd * cappedSeconds / worstSeconds;

  String get shareOfFreeCredit =>
      '${(worstCostUsd / JevPricing.freeCreditUsd * 100).toStringAsFixed(1)}%';
}

/// Worst-case calls, tokens, time and cost for [cfg]. Pass a probe's
/// measurements to replace the guess model where available.
PlanEstimate estimatePlan(
  DemoConfig cfg, {
  JevPricing pricing = const JevPricing(),
  Map<int, int> feasibleK = const {},
  Map<int, int> probeTokens = const {},
  Map<int, Duration> probeLatency = const {},
}) {
  Maze mazeFor(int size) =>
      Maze.generate(size, seed: cfg.seed + size * 1000, algo: cfg.algo);

  int kFor(int size) {
    final max = feasibleK[size];
    return max == null ? cfg.k : (max < cfg.k ? max : cfg.k);
  }

  bool infeasible(int size, int tokens) =>
      feasibleK[size] == 0 || (feasibleK[size] == null && tokens > tokenBudget);

  int tokensFor(int size, Maze maze) =>
      probeTokens[size] ?? estimateInputTokens(maze, kFor(size));

  int latencyFor(int size) =>
      probeLatency[size]?.inMilliseconds ??
      latencyGuessMs[size] ??
      (size * 40); // crude fallback for unlisted sizes

  final rows = <SizeEstimate>[];
  for (final p in cfg.plan) {
    final maze = mazeFor(p.size);
    final hard = DemoConfig.hardCapMultiplier * maze.solutionLength;
    final cap = p.iterCap == null ? hard : (p.iterCap! < hard ? p.iterCap! : hard);
    final tokens = tokensFor(p.size, maze);
    rows.add(SizeEstimate(
      size: p.size,
      width: maze.width,
      chars: maze.charCount,
      inputTokens: tokens,
      measured: probeTokens.containsKey(p.size),
      optimal: maze.solutionLength,
      trials: p.trials,
      cap: cap,
      worstCalls: p.trials * (cap + 1), // +1 for the at-goal NONE check
      latencyMs: latencyFor(p.size),
      infeasible: infeasible(p.size, tokens),
    ));
  }

  // Overhead phases. The probe stops sending after the first infeasible size,
  // and halves k up to ~7 times on a 422, so count each size once at full k.
  var overheadCalls = 0;
  var overheadTokens = 0;
  var overheadSeconds = 0.0;
  void add(int size, int calls) {
    final maze = mazeFor(size);
    final tokens = tokensFor(size, maze);
    if (infeasible(size, tokens)) return;
    overheadCalls += calls;
    overheadTokens += calls * tokens;
    overheadSeconds += calls * latencyFor(size) / 1000;
  }

  var firstFail = false;
  for (final size in [...cfg.probeSizes]..sort()) {
    if (firstFail) break;
    final maze = mazeFor(size);
    final tokens = tokensFor(size, maze);
    if (infeasible(size, tokens)) {
      firstFail = true;
      // One rejected call still costs nothing but time; count the attempt.
      overheadCalls += 1;
      overheadSeconds += latencyFor(size) / 1000;
      continue;
    }
    add(size, 1);
  }
  for (final size in cfg.phrasingSizes) {
    add(size, cfg.phrasingTrials * Phrasing.values.length);
  }
  add(cfg.independenceSize, cfg.independenceTrials * cfg.independenceKs.length);

  return PlanEstimate(
    cfg: cfg,
    pricing: pricing,
    rows: rows,
    overheadCalls: overheadCalls,
    overheadTokens: overheadTokens,
    overheadSeconds: overheadSeconds,
  );
}

String _min(double seconds) => '${(seconds / 60).toStringAsFixed(1)} min';

/// The full napkin-math table.
String formatEstimate(PlanEstimate e) {
  final cfg = e.cfg;
  final sb = StringBuffer()
    ..writeln('Napkin math for preset "${cfg.preset}" (k=${cfg.k}, '
        'time budget ${cfg.timeBudget.inMinutes} min, hard cap = '
        '${DemoConfig.hardCapMultiplier} x optimal moves)')
    ..writeln();
  final rows = [
    for (final r in e.rows)
      [
        '${r.size}',
        '${r.width}x${r.width}',
        '${r.chars}',
        '${r.measured ? '' : '~'}${r.inputTokens}${r.infeasible ? ' (over)' : ''}',
        '${r.optimal}',
        '${r.trials}',
        '${r.cap}',
        '${r.worstCalls}',
        '${(r.latencyMs / 1000).toStringAsFixed(2)}s',
        r.infeasible ? 'skip' : _min(r.worstSeconds),
        r.infeasible ? 'skip' : JevPricing.usd(e.pricing.cost(inputTokens: r.worstTokens)),
      ],
  ];
  sb.writeln(table(
    ['size', 'grid', 'chars', 'inputTok', 'optimal', 'trials', 'cap', 'worstCalls', 'lat', 'worstTime', 'worstCost'],
    rows,
  ));
  sb
    ..writeln()
    ..writeln('sweep worst case:   ${e.sweepCalls} calls, ${_fmtTokens(e.sweepTokens)} input tokens, '
        '${_min(e.sweepSeconds)}, ${JevPricing.usd(e.pricing.cost(inputTokens: e.sweepTokens))}')
    ..writeln('probe/phrasing/independence: ~${e.overheadCalls} calls, ${_fmtTokens(e.overheadTokens)} tokens, '
        '${_min(e.overheadSeconds)}, ${JevPricing.usd(e.pricing.cost(inputTokens: e.overheadTokens))}')
    ..writeln(summaryLine(e))
    ..writeln()
    ..writeln('Episodes end early on goal, on two consecutive stalls, or when the time budget')
    ..writeln('is hit, so the real run is usually well under the worst case. Output tokens are')
    ..writeln('free. Values marked ~ use a $charsPerToken chars/token guess; a probe replaces them.');
  return sb.toString();
}

/// Two lines: what the run could cost and how long it could take.
String summaryLine(PlanEstimate e) {
  final capped = e.cappedSeconds < e.worstSeconds;
  final time = capped
      ? '${_min(e.worstSeconds)} worst case, hard-stopped at ${_min(e.cappedSeconds)} by the time budget'
      : '${_min(e.worstSeconds)} worst case';
  final cost = capped
      ? '${JevPricing.usd(e.worstCostUsd)} worst case, ~${JevPricing.usd(e.cappedCostUsd)} within the time budget'
      : JevPricing.usd(e.worstCostUsd);
  return 'ESTIMATE: up to ${e.totalCalls} calls, ${_fmtTokens(e.totalTokens)} input tokens; '
      'time $time; cost $cost '
      '(${e.shareOfFreeCredit} of the \$${JevPricing.freeCreditUsd.toStringAsFixed(2)} free credit '
      'at \$${e.pricing.inputUsdPerMTok}/MTok input)';
}

String _fmtTokens(int t) => t >= 1000000
    ? '${(t / 1e6).toStringAsFixed(2)}M'
    : t >= 1000
        ? '${(t / 1e3).toStringAsFixed(0)}k'
        : '$t';

/// Simple fixed-width table used by the CLI and the report.
String table(List<String> header, List<List<String>> rows) {
  final widths = List<int>.generate(header.length, (i) => header[i].length);
  for (final row in rows) {
    for (var i = 0; i < row.length && i < widths.length; i++) {
      if (row[i].length > widths[i]) widths[i] = row[i].length;
    }
  }
  String line(List<String> cells) => [
        for (var i = 0; i < widths.length; i++)
          (i < cells.length ? cells[i] : '').padRight(widths[i]),
      ].join('  ').trimRight();
  return [line(header), widths.map((w) => '-' * w).join('  '), ...rows.map(line)].join('\n');
}
