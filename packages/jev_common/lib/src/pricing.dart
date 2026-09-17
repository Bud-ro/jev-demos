/// Jev list pricing, used for estimates and for reporting actual spend.
///
/// As of 2026-09-16: $0.042 per million input tokens, output free, with
/// $5.00 of free credit on a new account. Override with
/// `TYPESAFE_INPUT_USD_PER_MTOK` / `TYPESAFE_OUTPUT_USD_PER_MTOK` if it changes.
class JevPricing {
  const JevPricing({this.inputUsdPerMTok = 0.042, this.outputUsdPerMTok = 0});

  factory JevPricing.fromEnv(Map<String, String> env) => JevPricing(
        inputUsdPerMTok:
            double.tryParse(env['TYPESAFE_INPUT_USD_PER_MTOK'] ?? '') ?? 0.042,
        outputUsdPerMTok:
            double.tryParse(env['TYPESAFE_OUTPUT_USD_PER_MTOK'] ?? '') ?? 0,
      );

  final double inputUsdPerMTok;
  final double outputUsdPerMTok;

  /// Free credit granted to a new account, for context in estimates.
  static const freeCreditUsd = 5.0;

  double cost({required int inputTokens, int outputTokens = 0}) =>
      inputTokens / 1e6 * inputUsdPerMTok +
      outputTokens / 1e6 * outputUsdPerMTok;

  /// `$0.0123` style, with enough digits to show sub-cent amounts.
  static String usd(double v) =>
      v >= 1 ? '\$${v.toStringAsFixed(2)}' : '\$${v.toStringAsFixed(4)}';

  Map<String, Object?> toJson() => {
        'inputUsdPerMTok': inputUsdPerMTok,
        'outputUsdPerMTok': outputUsdPerMTok,
      };
}
