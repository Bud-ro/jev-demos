/// Shared scaffold for Jev demos.
///
/// - [JevClient]: thin typed shim over `POST /v1/systemone`.
/// - [loadEnv] / [requireEnv]: `.env` + process environment.
/// - [JsonlWriter] / [RunDir]: append-only result recording.
library;

export 'src/client.dart';
export 'src/env.dart';
export 'src/pricing.dart';
export 'src/recorder.dart';
