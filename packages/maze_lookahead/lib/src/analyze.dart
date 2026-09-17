import 'dart:convert';
import 'dart:io';

import 'package:jev_common/jev_common.dart';

/// Reads a run directory and produces `summary.json` plus a printable report.
///
/// Two views of the same data:
/// - **Mode A ("follow step 1")**: from `episodes.jsonl` / `trajectory.jsonl`.
///   Did the loop reach the goal, how many iterations, how many moves before
///   the first error, how far it got.
/// - **Mode B ("follow all steps")**: from each request's k-step prediction in
///   `requests.jsonl`. How many predicted moves are valid / optimal before the
///   first error, and a per-depth accuracy curve.
class RunAnalysis {
  RunAnalysis(this.summary, this.report);
  final Map<String, Object?> summary;
  final String report;
}

Future<RunAnalysis> analyzeRun(Directory dir) async {
  final run = RunDir(dir);
  final episodes = readJsonl(run.file('episodes.jsonl'))
      .where((e) => e['skipped'] != true)
      .toList();
  final requests = readJsonl(run.file('requests.jsonl'));
  final probe = readJsonl(run.file('probe.jsonl'));
  final meta = _readJson(run.file('run.json'));
  final phrasing = _readJson(run.file('phrasing_summary.json'));
  final independence = _readJson(run.file('independence_summary.json'));

  final sweep = requests
      .where((r) => r['phase'] == 'sweep' && r['status'] == 'ok')
      .toList();
  final sizes = {
    ...episodes.map((e) => e['size'] as int),
    ...sweep.map((r) => r['size'] as int),
  }.toList()
    ..sort();

  final perSize = <String, Object?>{};
  final out = StringBuffer();

  // ---- Probe --------------------------------------------------------------
  if (probe.isNotEmpty) {
    out.writeln('Probe (does the maze fit, and how many step questions ride along?)');
    out.writeln(_table(
      ['size', 'grid', 'chars', 'status', 'k', 'inputTok', 'latencyMs', 'mazeChars/tok'],
      [
        for (final p in probe)
          [
            '${p['size']}',
            '${p['width']}x${p['width']}',
            '${p['chars']}',
            '${p['status']}',
            '${p['k'] ?? ''}',
            '${p['inputTokens'] ?? ''}',
            '${p['latencyMs'] ?? ''}',
            p['mazeCharsPerToken'] == null
                ? ''
                : (p['mazeCharsPerToken'] as num).toStringAsFixed(2),
          ],
      ],
    ));
    out.writeln();
  }

  // ---- Phrasing -----------------------------------------------------------
  if (phrasing != null) {
    final by = phrasing['byPhrasing'] as Map<String, dynamic>;
    out.writeln('Phrasing experiment (one request per maze, best = ${phrasing['best']}, '
        'used = ${phrasing['used']})');
    out.writeln(_table(
      ['phrasing', 'n', 'meanValid', 'meanOptimal', 'completed', 'meanTok'],
      [
        for (final e in by.entries)
          [
            e.key,
            '${e.value['n']}',
            _f(e.value['meanValidPrefix']),
            _f(e.value['meanOptimalPrefix']),
            '${e.value['completed']}',
            _f(e.value['meanInputTokens'], 0),
          ],
      ],
    ));
    out.writeln();
  }

  // ---- Independence -------------------------------------------------------
  if (independence != null) {
    final trials = (independence['trials'] as List).cast<Map<String, dynamic>>();
    final agree = trials.where((t) => t['step1Agree'] == true).length;
    final prefixAgree = trials.where((t) => t['sharedPrefixAgree'] == true).length;
    final maxDiff = trials.isEmpty
        ? 0.0
        : trials.map((t) => (t['step1MaxProbDiff'] as num).toDouble()).reduce((a, b) => a > b ? a : b);
    out.writeln('Independence check (size ${independence['size']}, k in ${independence['ks']})');
    out.writeln('  step-1 answer identical across k: $agree/${trials.length} trials');
    out.writeln('  shared move prefix identical across k: $prefixAgree/${trials.length} trials');
    out.writeln('  largest step-1 probability drift: ${maxDiff.toStringAsFixed(4)}');
    out.writeln();
  }

  // ---- Per size -----------------------------------------------------------
  final modeARows = <List<String>>[];
  final modeBRows = <List<String>>[];
  final depthTables = <String, List<Map<String, Object?>>>{};

  for (final size in sizes) {
    final eps = episodes.where((e) => e['size'] == size).toList();
    final reqs = sweep.where((r) => r['size'] == size).toList();
    final firstReqs = reqs.where((r) => r['iteration'] == 0).toList();
    final planning = reqs.where((r) => r['atGoalCheck'] != true).toList();

    // Mode A
    final solved = eps.where((e) => e['solved'] == true).toList();
    final errorTotals = <String, int>{};
    final endReasons = <String, int>{};
    for (final e in eps) {
      for (final err in (e['errors'] as Map<String, dynamic>).entries) {
        errorTotals[err.key] = (errorTotals[err.key] ?? 0) + (err.value as int);
      }
      final reason = '${e['endReason']}';
      endReasons[reason] = (endReasons[reason] ?? 0) + 1;
    }
    final modeA = {
      'trials': eps.length,
      'solved': solved.length,
      'solveRate': _ratio(solved.length, eps.length),
      'saidNoneAtGoal': solved.where((e) => e['saidNoneAtGoal'] == true).length,
      'meanIterationsSolved': _mean(solved.map((e) => e['iterations'] as num)),
      'meanSolutionLength': _mean(eps.map((e) => e['solutionLength'] as num)),
      'meanOvershoot': _mean(solved.map(
          (e) => (e['iterations'] as num) / (e['solutionLength'] as num))),
      'meanMovesBeforeFirstError': _mean(eps.map((e) => e['movesBeforeFirstError'] as num)),
      'maxMovesBeforeFirstError': _max(eps.map((e) => e['movesBeforeFirstError'] as num)),
      'meanProgress': _mean(eps.map((e) => e['progress'] as num)),
      'errors': errorTotals,
      'endReasons': endReasons,
    };

    // Mode B
    Iterable<num> evalOf(String key, List<Map<String, dynamic>> rs) =>
        rs.map((r) => (r['eval'] as Map<String, dynamic>)[key] as num);
    final modeB = {
      'requestsFromStart': firstReqs.length,
      'meanValidPrefix': _mean(evalOf('validPrefix', firstReqs)),
      'maxValidPrefix': _max(evalOf('validPrefix', firstReqs)),
      'meanOptimalPrefix': _mean(evalOf('optimalPrefix', firstReqs)),
      'maxOptimalPrefix': _max(evalOf('optimalPrefix', firstReqs)),
      'meanOptimalRemaining': _mean(evalOf('optimalRemaining', firstReqs)),
      'completedFromStart': firstReqs
          .where((r) => (r['eval'] as Map<String, dynamic>)['completed'] == true)
          .length,
      'allRequests': planning.length,
      'meanValidPrefixAll': _mean(evalOf('validPrefix', planning)),
      'meanOptimalPrefixAll': _mean(evalOf('optimalPrefix', planning)),
      'meanInputTokens': _mean(reqs.map((r) => (r['usage'] as Map<String, dynamic>)['input_tokens'] as num)),
      'meanLatencyMs': _mean(reqs.map((r) => r['latencyMs'] as num)),
    };

    // Depth curve: P(step n is the optimal move | n within remaining path).
    final depth = <Map<String, Object?>>[];
    if (planning.isNotEmpty) {
      final k = planning.map((r) => r['k'] as int).reduce((a, b) => a > b ? a : b);
      for (var n = 1; n <= k; n++) {
        var eligible = 0, correct = 0, valid = 0;
        var confSum = 0.0;
        for (final r in planning) {
          final eval = r['eval'] as Map<String, dynamic>;
          final remaining = eval['optimalRemaining'] as int;
          if (n > remaining + 1) continue; // beyond the path (+1 for terminal NONE)
          final match = eval['optimalMatch'] as String;
          final validBits = eval['valid'] as String;
          if (n > match.length) continue; // replay stopped at an earlier NONE
          eligible++;
          if (match[n - 1] == '1') correct++;
          if (validBits[n - 1] == '1') valid++;
          final answers = r['answers'] as List;
          confSum += (answers[n - 1]['conf'] as num).toDouble();
        }
        if (eligible == 0) break;
        depth.add({
          'n': n,
          'eligible': eligible,
          'optimalRate': correct / eligible,
          'validRate': valid / eligible,
          'meanConfidence': confSum / eligible,
        });
      }
    }
    depthTables['$size'] = depth;

    perSize['$size'] = {'modeA': modeA, 'modeB': modeB, 'depth': depth};

    modeARows.add([
      '$size',
      '${eps.length}',
      '${solved.length}',
      _f(modeA['meanIterationsSolved']),
      _f(modeA['meanSolutionLength']),
      _f(modeA['meanOvershoot']),
      _f(modeA['meanMovesBeforeFirstError']),
      '${modeA['maxMovesBeforeFirstError'] ?? ''}',
      _f(modeA['meanProgress']),
      errorTotals.entries.map((e) => '${e.key}=${e.value}').join(' '),
      endReasons.entries.map((e) => '${e.key}=${e.value}').join(' '),
    ]);
    modeBRows.add([
      '$size',
      '${firstReqs.length}',
      _f(modeB['meanValidPrefix']),
      '${modeB['maxValidPrefix'] ?? ''}',
      _f(modeB['meanOptimalPrefix']),
      '${modeB['maxOptimalPrefix'] ?? ''}',
      _f(modeB['meanOptimalRemaining']),
      '${modeB['completedFromStart']}',
      _f(modeB['meanInputTokens'], 0),
      _f(modeB['meanLatencyMs'], 0),
    ]);
  }

  if (modeARows.isNotEmpty) {
    out.writeln('Mode A: follow step 1 in a loop (per maze size)');
    out.writeln(_table(
      [
        'size', 'trials', 'solved', 'itersSolved', 'optimal', 'overshoot',
        'cleanMoves', 'maxClean', 'progress', 'errors', 'endReasons'
      ],
      modeARows,
    ));
    out.writeln('  itersSolved = mean iterations for solved mazes; optimal = mean shortest path;');
    out.writeln('  overshoot = iterations / optimal; cleanMoves = moves before the first error;');
    out.writeln('  progress = share of the start distance closed at the closest point reached.');
    out.writeln();
  }
  if (modeBRows.isNotEmpty) {
    out.writeln('Mode B: follow ALL predicted steps from the start position (one request)');
    out.writeln(_table(
      [
        'size', 'n', 'validPrefix', 'maxValid', 'optimalPrefix', 'maxOptimal',
        'pathLen', 'completed', 'inputTok', 'latencyMs'
      ],
      modeBRows,
    ));
    out.writeln('  validPrefix = predicted moves before the first error (wall / backtrack /');
    out.writeln('  off-goal / premature NONE); optimalPrefix = predicted moves matching the');
    out.writeln('  unique shortest path; completed = reached G then said NONE.');
    out.writeln();

    out.writeln('Lookahead accuracy by depth (all sweep requests, P(step n is the optimal move))');
    final checkpoints = [1, 2, 3, 5, 8, 10, 15, 20, 30, 50, 75, 100];
    out.writeln(_table(
      ['size', ...checkpoints.map((n) => 'n=$n')],
      [
        for (final size in sizes)
          [
            '$size',
            for (final n in checkpoints)
              () {
                final row = depthTables['$size']!.where((d) => d['n'] == n).firstOrNull;
                if (row == null) return '';
                final rate = (row['optimalRate'] as double) * 100;
                return '${rate.round()}%(${row['eligible']})';
              }(),
          ],
      ],
    ));
    out.writeln();
  }

  if (meta != null) {
    out.writeln('Run: ${dir.path}');
    out.writeln('  preset=${(meta['config'] as Map)['preset']} mock=${meta['mock']} '
        'phrasing=${meta['phrasingUsed']} calls=${meta['calls']} '
        'inputTokens=${meta['inputTokens']} elapsed=${meta['elapsedSec']}s '
        'apiTime=${meta['apiTimeSec']}s budgetHit=${meta['budgetHit']}');
    if (meta['costUsd'] != null) {
      out.writeln('  spend: ${JevPricing.usd((meta['costUsd'] as num).toDouble())} '
          '(list price, output free)');
    }
  }

  final summary = {
    'run': dir.path,
    'meta': meta,
    'sizes': sizes,
    'perSize': perSize,
    'phrasing': phrasing,
    'independence': independence,
    'probe': probe,
  };
  await run.writeJson('summary.json', summary);
  await run.file('report.txt').writeAsString(out.toString());
  return RunAnalysis(summary, out.toString());
}

Map<String, dynamic>? _readJson(File f) =>
    f.existsSync() ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic> : null;

double? _mean(Iterable<num> xs) {
  final list = xs.toList();
  if (list.isEmpty) return null;
  return list.fold<double>(0, (a, b) => a + b) / list.length;
}

num? _max(Iterable<num> xs) {
  final list = xs.toList();
  if (list.isEmpty) return null;
  return list.reduce((a, b) => a > b ? a : b);
}

double? _ratio(int a, int b) => b == 0 ? null : a / b;

String _f(Object? v, [int digits = 2]) =>
    v == null ? '' : (v as num).toStringAsFixed(digits);

String _table(List<String> header, List<List<String>> rows) {
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
  final sb = StringBuffer()
    ..writeln('  ${line(header)}')
    ..writeln('  ${widths.map((w) => '-' * w).join('  ')}');
  for (final row in rows) {
    sb.writeln('  ${line(row)}');
  }
  return sb.toString().trimRight();
}
