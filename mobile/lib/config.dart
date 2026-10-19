/// Build-time configuration (pass with --dart-define).
///
///   flutter run -d chrome \
///     --dart-define=KAVACH_API_BASE=http://localhost:8010 \
///     --dart-define=SUPABASE_URL=https://xyzcompany.supabase.co \
///     --dart-define=SUPABASE_ANON_KEY=eyJ...
///
/// Without the Supabase values the app falls back to the backend's built-in
/// demo auth and keeps watchlists / portfolios in local browser storage.
class Config {
  static const apiBase = String.fromEnvironment('KAVACH_API_BASE', defaultValue: 'http://localhost:8010');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get hasSupabase => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
