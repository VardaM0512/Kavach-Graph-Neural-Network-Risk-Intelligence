import 'package:flutter/foundation.dart';

/// Build-time configuration (pass with --dart-define).
///
///   flutter run -d chrome \
///     --dart-define=KAVACH_API_BASE=http://localhost:8010 \
///     --dart-define=SUPABASE_URL=https://xyzcompany.supabase.co \
///     --dart-define=SUPABASE_ANON_KEY=eyJ...
///
/// Without the Supabase values the app falls back to the backend's built-in
/// demo auth and keeps watchlists / portfolios in local browser storage. When
/// the web client and API share an origin, the API base is detected at runtime.
class Config {
  static const apiBase = String.fromEnvironment('KAVACH_API_BASE');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static String get resolvedApiBase {
    if (apiBase.isNotEmpty) return apiBase;
    return kIsWeb ? Uri.base.origin : 'http://localhost:8010';
  }

  static bool get hasSupabase => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
