import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'services/api_client.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'screens/login_screen.dart';
import 'screens/home_shell.dart';

void main() {
  runApp(const KavachApp());
}

class KavachApp extends StatelessWidget {
  const KavachApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiClient>(create: (_) => ApiClient()),
        ChangeNotifierProvider<AppState>(
          create: (ctx) => AppState(ctx.read<ApiClient>())..bootstrap(),
        ),
      ],
      child: Consumer<AppState>(
        builder: (context, state, _) => MaterialApp(
          title: 'Kavach',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeMode.system,
          locale: state.locale,
          supportedLocales: const [
            Locale('en'), Locale('hi'), Locale('ta'),
          ],
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: state.isAuthenticated ? const HomeShell() : const LoginScreen(),
        ),
      ),
    );
  }
}
