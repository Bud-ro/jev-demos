import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jev_common/jev_common.dart';
import 'package:test/test.dart';

void main() {
  group('JevClient', () {
    test('serializes questions and parses typed answers', () async {
      late Map<String, dynamic> sent;
      final mock = MockClient((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        expect(req.headers['Authorization'], 'Bearer k');
        return http.Response(
          jsonEncode({
            'model': 'jev-latest',
            'answers': {
              'urgent': {'type': 'noul', 'noul': 0.9},
              'dept': {
                'type': 'choice',
                'choice': 'tech',
                'probabilities': {'tech': 0.8, 'billing': 0.2},
                'confidence': 0.7,
              },
              'mood': {
                'type': 'score',
                'score': 1.5,
                'legend': {'0': 'calm', '1': 'meh', '2': 'angry'},
                'probabilities': {'0': 0.1, '1': 0.3, '2': 0.6},
                'confidence': 0.5,
              },
            },
            'usage': {'input_tokens': 10, 'output_tokens': 3},
          }),
          200,
        );
      });
      final client = JevClient(apiKey: 'k', httpClient: mock);
      final res = await client.systemOne(
        state: {'msg': 'hi'},
        questions: {
          'urgent': const Noul('Urgent?', whenTrue: 'yes it is'),
          'dept': const Choice('Which?', {'tech': null, 'billing': 'money'}),
          'mood': const Score('Mood', ['calm', 'meh', 'angry']),
        },
      );
      expect(sent['model'], 'jev-latest');
      expect(sent['questions']['urgent']['criteria'], {'true': 'yes it is'});
      expect(sent['questions']['dept']['criteria'], {'tech': null, 'billing': 'money'});
      expect(sent['questions']['mood']['criteria'], ['calm', 'meh', 'angry']);
      expect(res.noul('urgent').noul, 0.9);
      expect(res.choice('dept').choice, 'tech');
      expect(res.score('mood').legend['2'], 'angry');
      expect(res.usage.inputTokens, 10);
      expect(res.attempts, 1);
    });

    test('retries on 429 then succeeds', () async {
      var calls = 0;
      final mock = MockClient((req) async {
        calls++;
        if (calls < 3) return http.Response('{"error":"slow down"}', 429);
        return http.Response(
          jsonEncode({
            'model': 'jev-latest',
            'answers': {'q': {'type': 'noul', 'noul': 0.5}},
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          }),
          200,
        );
      });
      final client = JevClient(
        apiKey: 'k',
        httpClient: mock,
        retry: const RetryPolicy(initialBackoff: Duration(milliseconds: 1)),
      );
      final res = await client.systemOne(state: 's', questions: {'q': const Noul('?')});
      expect(res.attempts, 3);
    });

    test('throws JevApiException on 422 without retry', () async {
      final mock = MockClient((req) async => http.Response('{"detail":"bad"}', 422));
      final client = JevClient(apiKey: 'k', httpClient: mock);
      expect(
        () => client.systemOne(state: 's', questions: {'q': const Noul('?')}),
        throwsA(isA<JevApiException>().having((e) => e.isValidation, 'isValidation', true)),
      );
    });
  });

  group('loadEnv', () {
    test('parses a .env file and lets process env win', () {
      final dir = Directory.systemTemp.createTempSync('jevenv');
      File('${dir.path}/.env').writeAsStringSync(
        '# comment\nexport A=1\nB="two words"\nC=three # trailing\nPATH=nope\n',
      );
      final sub = Directory('${dir.path}/nested/deeper')..createSync(recursive: true);
      final env = loadEnv(from: sub);
      expect(env['A'], '1');
      expect(env['B'], 'two words');
      expect(env['C'], 'three');
      expect(env['PATH'], isNot('nope'));
      dir.deleteSync(recursive: true);
    });
  });
}
