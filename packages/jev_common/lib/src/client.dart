import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// Questions
// ---------------------------------------------------------------------------

/// A typed System One question. `instructions` may be a string or any
/// JSON-encodable structure (object/array), per the TypeSafe API.
sealed class Question {
  const Question(this.instructions);
  final Object instructions;
  String get type;
  Map<String, Object?> toJson();
}

/// Yes/no. Answer is the probability of yes.
class Noul extends Question {
  const Noul(super.instructions, {this.whenTrue, this.whenFalse});
  final String? whenTrue;
  final String? whenFalse;

  @override
  String get type => 'noul';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'instructions': instructions,
        if (whenTrue != null || whenFalse != null)
          'criteria': {
            if (whenTrue != null) 'true': whenTrue,
            if (whenFalse != null) 'false': whenFalse,
          },
      };
}

/// One option from a fixed set. Map option -> description (or null).
class Choice extends Question {
  const Choice(super.instructions, this.criteria);
  final Map<String, String?> criteria;

  @override
  String get type => 'choice';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'instructions': instructions,
        'criteria': criteria,
      };
}

/// A position along ordered levels (at least two).
class Score extends Question {
  const Score(super.instructions, this.levels);

  /// Ordered level descriptions; the API requires at least two.
  final List<String> levels;

  @override
  String get type => 'score';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'instructions': instructions,
        'criteria': levels,
      };
}

// ---------------------------------------------------------------------------
// Answers
// ---------------------------------------------------------------------------

sealed class Answer {
  const Answer();
  String get type;
  Map<String, Object?> toJson();

  static Answer fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'noul':
        return NoulAnswer((json['noul'] as num).toDouble());
      case 'choice':
        return ChoiceAnswer(
          json['choice'] as String,
          _probs(json['probabilities']),
          (json['confidence'] as num).toDouble(),
        );
      case 'score':
        return ScoreAnswer(
          (json['score'] as num).toDouble(),
          (json['legend'] as Map).map((k, v) => MapEntry('$k', '$v')),
          _probs(json['probabilities']),
          (json['confidence'] as num).toDouble(),
        );
      default:
        throw FormatException('Unknown answer type: ${json['type']}');
    }
  }

  static Map<String, double> _probs(Object? raw) =>
      (raw as Map).map((k, v) => MapEntry('$k', (v as num).toDouble()));
}

class NoulAnswer extends Answer {
  const NoulAnswer(this.noul);
  final double noul;
  @override
  String get type => 'noul';
  @override
  Map<String, Object?> toJson() => {'type': type, 'noul': noul};
}

class ChoiceAnswer extends Answer {
  const ChoiceAnswer(this.choice, this.probabilities, this.confidence);
  final String choice;
  final Map<String, double> probabilities;
  final double confidence;
  @override
  String get type => 'choice';
  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'choice': choice,
        'probabilities': probabilities,
        'confidence': confidence,
      };
}

class ScoreAnswer extends Answer {
  const ScoreAnswer(this.score, this.legend, this.probabilities, this.confidence);
  final double score;
  final Map<String, String> legend;
  final Map<String, double> probabilities;
  final double confidence;
  @override
  String get type => 'score';
  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'score': score,
        'legend': legend,
        'probabilities': probabilities,
        'confidence': confidence,
      };
}

class Usage {
  const Usage(this.inputTokens, this.outputTokens);
  final int inputTokens;
  final int outputTokens;
  Map<String, Object?> toJson() =>
      {'input_tokens': inputTokens, 'output_tokens': outputTokens};
}

class SystemOneResponse {
  const SystemOneResponse({
    required this.model,
    required this.answers,
    required this.usage,
    required this.latency,
    required this.attempts,
  });

  final String model;
  final Map<String, Answer> answers;
  final Usage usage;

  /// Wall-clock time of the final (successful) HTTP attempt.
  final Duration latency;

  /// Number of HTTP attempts made, including retries.
  final int attempts;

  NoulAnswer noul(String id) => answers[id] as NoulAnswer;
  ChoiceAnswer choice(String id) => answers[id] as ChoiceAnswer;
  ScoreAnswer score(String id) => answers[id] as ScoreAnswer;
}

// ---------------------------------------------------------------------------
// Errors & retries
// ---------------------------------------------------------------------------

class JevApiException implements Exception {
  JevApiException(this.status, this.body, {this.attempts = 1});
  final int status;
  final String body;
  final int attempts;

  bool get isAuth => status == 401;
  bool get isValidation => status == 422;
  bool get isRateLimit => status == 429;
  bool get isOverloaded => status == 529;

  @override
  String toString() {
    final short = body.length > 400 ? '${body.substring(0, 400)}…' : body;
    return 'JevApiException(HTTP $status after $attempts attempt(s)): $short';
  }
}

class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 5,
    this.initialBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 20),
    this.retryOn = const {429, 529, 500, 502, 503, 504},
  });

  final int maxAttempts;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final Set<int> retryOn;

  Duration backoffFor(int attempt, math.Random rng) {
    final base = initialBackoff.inMilliseconds * math.pow(2, attempt - 1);
    final capped = math.min(base, maxBackoff.inMilliseconds.toDouble());
    final jitter = rng.nextDouble() * 0.25 * capped;
    return Duration(milliseconds: (capped + jitter).round());
  }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Minimal client for `POST {baseUrl}/v1/systemone`.
///
/// Calls are made strictly sequentially by the caller; this client does not
/// add concurrency. Retries with exponential backoff on 429/529/5xx.
class JevClient {
  JevClient({
    required this.apiKey,
    Uri? baseUrl,
    this.model = 'jev-latest',
    http.Client? httpClient,
    this.retry = const RetryPolicy(),
    this.timeout = const Duration(seconds: 120),
    math.Random? random,
  })  : baseUrl = baseUrl ?? Uri.parse('https://api.typesafe.ai'),
        _http = httpClient ?? http.Client(),
        _rng = random ?? math.Random();

  /// Builds a client from the environment (`TYPESAFE_API_KEY`, optional
  /// `TYPESAFE_BASE_URL`, `TYPESAFE_MODEL`).
  factory JevClient.fromEnv(Map<String, String> env, {http.Client? httpClient}) {
    final key = env['TYPESAFE_API_KEY'];
    if (key == null || key.isEmpty) {
      throw StateError(
        'TYPESAFE_API_KEY is not set. Copy .env.example to .env and fill it in.',
      );
    }
    final base = env['TYPESAFE_BASE_URL'];
    return JevClient(
      apiKey: key,
      baseUrl: base == null || base.isEmpty ? null : Uri.parse(base),
      model: env['TYPESAFE_MODEL'] ?? 'jev-latest',
      httpClient: httpClient,
    );
  }

  final String apiKey;
  final Uri baseUrl;
  final String model;
  final RetryPolicy retry;
  final Duration timeout;
  final http.Client _http;
  final math.Random _rng;

  Uri get endpoint => baseUrl.replace(path: '/v1/systemone');

  /// Serializes a request body without sending it. Useful for token/size
  /// estimates and for logging.
  Map<String, Object?> buildBody({
    required Object state,
    required Map<String, Question> questions,
    String? model,
  }) =>
      {
        'state': state,
        'model': model ?? this.model,
        'questions': questions.map((k, q) => MapEntry(k, q.toJson())),
      };

  /// Evaluates [state] against [questions]. All questions see the same state
  /// and are answered independently.
  Future<SystemOneResponse> systemOne({
    required Object state,
    required Map<String, Question> questions,
    String? model,
  }) async {
    final body = jsonEncode(buildBody(state: state, questions: questions, model: model));
    var attempt = 0;
    while (true) {
      attempt++;
      final sw = Stopwatch()..start();
      http.Response res;
      try {
        res = await _http
            .post(
              endpoint,
              headers: {
                'Authorization': 'Bearer $apiKey',
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: body,
            )
            .timeout(timeout);
      } on SocketException catch (e) {
        if (attempt >= retry.maxAttempts) {
          throw JevApiException(0, 'connection error: $e', attempts: attempt);
        }
        await Future<void>.delayed(retry.backoffFor(attempt, _rng));
        continue;
      }
      sw.stop();

      if (res.statusCode == 200) {
        final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final rawAnswers = (json['answers'] as Map<String, dynamic>);
        final usage = json['usage'] as Map<String, dynamic>? ?? const {};
        return SystemOneResponse(
          model: json['model'] as String? ?? (model ?? this.model),
          answers: rawAnswers.map(
            (k, v) => MapEntry(k, Answer.fromJson(v as Map<String, dynamic>)),
          ),
          usage: Usage(
            (usage['input_tokens'] as num?)?.toInt() ?? 0,
            (usage['output_tokens'] as num?)?.toInt() ?? 0,
          ),
          latency: sw.elapsed,
          attempts: attempt,
        );
      }

      if (retry.retryOn.contains(res.statusCode) && attempt < retry.maxAttempts) {
        await Future<void>.delayed(retry.backoffFor(attempt, _rng));
        continue;
      }
      throw JevApiException(res.statusCode, utf8.decode(res.bodyBytes),
          attempts: attempt);
    }
  }

  void close() => _http.close();
}
