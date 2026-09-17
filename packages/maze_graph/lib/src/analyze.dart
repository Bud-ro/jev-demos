import 'dart:convert';
import 'dart:io';

import 'package:jev_common/jev_common.dart';

class RunAnalysis {
  RunAnalysis(this.summary, this.report);
  final Map<String, Object?> summary;
  final String report;
}

Future<RunAnalysis> analyzeRun(Directory dir) async {
  final run = RunDir(dir);
  final episodes = readJsonl(run.file('episodes.jsonl')).where((e) => e['skipped'] != true).toList();
  final requests = readJsonl(run.file('requests.jsonl')).where((r) => r['status'] == 'ok').toList();
  final meta = run.file('run.json').existsSync()
      ? jsonDecode(run.file('run.json').readAsStringSync()) as Map<String, dynamic>
      : null;
  final sizes = episodes.map((e) => e['n'] as int).toSet().toList()..sort();
  final out = StringBuffer();
  final perSize = <String, Object?>{};

  double? mean(Iterable<num> xs) {
    final l = xs.toList();
    return l.isEmpty ? null : l.fold<double>(0, (a, b) => a + b) / l.length;
  }

  String f(Object? v, [int d = 2]) => v == null ? '' : (v as num).toStringAsFixed(d);
  String pct(Object? v) => v == null ? '' : '${((v as num) * 100).round()}%';

  final rows = <List<String>>[];
  final depthRows = <List<String>>[];
  const checkpoints = [1, 2, 3, 4, 5, 7, 10, 15, 20];
  for (final n in sizes) {
    final eps = episodes.where((e) => e['n'] == n).toList();
    final reqs = requests.where((r) => r['n'] == n).toList();
    final solved = eps.where((e) => e['solved'] == true).toList();
    final ends = <String, int>{};
    for (final e in eps) {
      ends['${e['endReason']}'] = (ends['${e['endReason']}'] ?? 0) + 1;
    }
    double? baseline(String policy, String key) => mean(eps.map((e) {
          final b = (e['baselines'] as List).cast<Map<String, dynamic>>().firstWhere((b) => b['policy'] == policy);
          return (b[key] as num?) ?? 0;
        }));
    final s = {
      'trials': eps.length,
      'solved': solved.length,
      'solveRate': eps.isEmpty ? null : solved.length / eps.length,
      'meanOptimal': mean(eps.map((e) => e['optimalMoves'] as num)),
      'meanMovesSolved': mean(solved.map((e) => e['moves'] as num)),
      'meanRatio': mean(solved.map((e) => e['ratio'] as num)),
      'optimalHopRate': mean(reqs.map((r) => r['optimalHop'] == true ? 1 : 0)),
      'revisitRate': mean(reqs.map((r) => r['revisit'] == true ? 1 : 0)),
      'forcedShare': mean(reqs.map((r) => (r['legalExits'] as int) == 1 ? 1 : 0)),
      'meanConfidence': mean(reqs.map((r) => r['confidence'] as num)),
      'progress': mean(eps.map((e) => e['progress'] as num)),
      'randomSolveRate': baseline('random', 'solveRate'),
      'randomMoves': baseline('random', 'meanMovesSolved'),
      'unvisitedSolveRate': baseline('unvisited', 'solveRate'),
      'unvisitedMoves': baseline('unvisited', 'meanMovesSolved'),
      'endReasons': ends,
      'meanInputTokens': mean(reqs.map((r) => (r['usage'] as Map)['input_tokens'] as num)),
      'meanLatencyMs': mean(reqs.map((r) => r['latencyMs'] as num)),
    };
    // Lookahead by depth: P(step i keeps the shortest distance decreasing).
    final depth = <Map<String, Object?>>[];
    final k = reqs.isEmpty ? 0 : reqs.map((r) => r['k'] as int).reduce((a, b) => a > b ? a : b);
    for (var i = 1; i <= k; i++) {
      var eligible = 0, hit = 0;
      for (final r in reqs) {
        final bits = (r['eval'] as Map)['optimalMatch'] as String;
        if (i > (r['distToGoal'] as int) || i > bits.length) continue;
        eligible++;
        if (bits[i - 1] == '1') hit++;
      }
      if (eligible == 0) break;
      depth.add({'n': i, 'eligible': eligible, 'optimalRate': hit / eligible});
    }
    s['depth'] = depth;
    perSize['$n'] = s;
    rows.add([
      '${n}x$n', '${eps.length}', '${solved.length}', f(s['meanOptimal'], 1), f(s['meanMovesSolved'], 1),
      f(s['meanRatio']), pct(s['optimalHopRate']), pct(s['revisitRate']), pct(s['forcedShare']),
      f(s['meanConfidence']), pct(s['randomSolveRate']), f(s['randomMoves'], 0),
      pct(s['unvisitedSolveRate']), f(s['unvisitedMoves'], 0),
      ends.entries.map((e) => '${e.key}=${e.value}').join(' '),
      f(s['meanInputTokens'], 0),
    ]);
    depthRows.add([
      '${n}x$n',
      for (final c in checkpoints)
        () {
          final d = depth.where((d) => d['n'] == c).firstOrNull;
          return d == null ? '' : '${((d['optimalRate'] as double) * 100).round()}%(${d['eligible']})';
        }(),
    ]);
  }

  out.writeln('Graph-state loop: one legal-exit Choice per move (pahndev methodology), per maze size');
  out.writeln(_table([
    'size', 'trials', 'solved', 'optimal', 'moves', 'ratio', 'bestHop', 'revisit', 'forced', 'conf',
    'rndSolve', 'rndMoves', 'unvSolve', 'unvMoves', 'end', 'inputTok'
  ], rows));
  out.writeln('  moves/ratio = for solved mazes, moves taken and moves/optimal; bestHop = share of moves');
  out.writeln('  that reduce the shortest distance; forced = share of moves with only one legal exit;');
  out.writeln('  rnd/unv = code baselines under the same cap: uniform random exit, and least-visited exit.');
  out.writeln();
  if (depthRows.any((r) => r.skip(1).any((c) => c.isNotEmpty))) {
    out.writeln('Lookahead by depth: P(move i reduces the shortest distance), move 1 = the legal-exit choice');
    out.writeln(_table(['size', ...checkpoints.map((c) => 'i=$c')], depthRows));
    out.writeln();
  }
  if (meta != null) {
    out.writeln('Run: ${dir.path}');
    out.writeln('  preset=${(meta['config'] as Map)['preset']} observation=${(meta['config'] as Map)['observation']} '
        'k=${(meta['config'] as Map)['k']} mock=${meta['mock']} calls=${meta['calls']} '
        'inputTokens=${meta['inputTokens']} elapsed=${meta['elapsedSec']}s budgetHit=${meta['budgetHit']}');
    out.writeln('  spend: ${JevPricing.usd((meta['costUsd'] as num).toDouble())}');
  }
  final summary = {'run': dir.path, 'meta': meta, 'sizes': sizes, 'perSize': perSize};
  await run.writeJson('summary.json', summary);
  await run.file('report.txt').writeAsString(out.toString());
  return RunAnalysis(summary, out.toString());
}

String _table(List<String> header, List<List<String>> rows) {
  final widths = List<int>.generate(header.length, (i) => header[i].length);
  for (final row in rows) {
    for (var i = 0; i < row.length && i < widths.length; i++) {
      if (row[i].length > widths[i]) widths[i] = row[i].length;
    }
  }
  String line(List<String> cells) =>
      [for (var i = 0; i < widths.length; i++) (i < cells.length ? cells[i] : '').padRight(widths[i])].join('  ').trimRight();
  return ['  ${line(header)}', '  ${widths.map((w) => '-' * w).join('  ')}', ...rows.map((r) => '  ${line(r)}')].join('\n');
}
