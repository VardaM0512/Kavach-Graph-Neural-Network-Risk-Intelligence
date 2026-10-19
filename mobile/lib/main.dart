import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'l10n/strings.dart';
import 'screens/landing_screen.dart';
import 'screens/shell.dart';
import 'services/account.dart';
import 'services/api_client.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'widgets/brand.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Config.hasSupabase) {
    await Supabase.initialize(url: Config.supabaseUrl, publishableKey: Config.supabaseAnonKey);
  }
  final api = ApiClient();
  final account = Config.hasSupabase ? SupabaseBackend() : LocalBackend(api);
  runApp(KavachApp(state: AppState(api, account)..bootstrap()));
}

/// Locales Flutter's Material widgets ship translations for.
const _materialLocales = ['en', 'hi', 'bn', 'te', 'mr', 'ta', 'ur', 'gu', 'kn', 'or', 'ml', 'pa', 'as', 'ne'];

class KavachApp extends StatelessWidget {
  final AppState state;
  const KavachApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: state,
      child: Consumer<AppState>(builder: (context, st, _) {
        final lang = langOf(st.lang);
        return MaterialApp(
          title: 'Kavach — Credit risk intelligence',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: st.themeMode,
          locale: Locale(lang.materialLocale),
          supportedLocales: [for (final l in _materialLocales) Locale(l)],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          // Kashmiri and Sindhi have no Material locale but are written right-to-left.
          builder: (context, child) => Directionality(
            textDirection: lang.rtl ? TextDirection.rtl : TextDirection.ltr,
            child: child!,
          ),
          home: !st.ready
              ? const _Splash()
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  child: st.isAuthenticated ? const Shell(key: ValueKey('shell')) : const LandingScreen(key: ValueKey('landing')),
                ),
        );
      }),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: KavachMark(size: 40)));
}
