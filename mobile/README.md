# Kavach Mobile (Flutter)

Cross-platform (Android + iOS) client for the Kavach Risk Intelligence API.

## Screens
- **Login** — JWT auth against `/api/auth/login` (demo: `demo@kavach.ai` / `demo1234`)
- **Dashboard** — tracked companies, risk-band summary, drill-down
- **Company** — distress risk, multi-horizon, financial health, explainability
- **Network graph** — interactive supplier/customer graph (colour = risk band)
- **Scenario** — revenue / rate / supplier-failure stress testing
- **Portfolio** — aggregate distress exposure + shared-network concentration
- **Alerts** — early-warning feed
- **Voice** — speak a query, hear a spoken multilingual answer
- **Settings** — language switch (English / हिन्दी / தமிழ்), sign out

## Run
```bash
flutter pub get
flutter gen-l10n            # builds lib/l10n/app_localizations.dart from the .arb files
# point the app at your backend (Android emulator -> host = 10.0.2.2):
flutter run --dart-define=KAVACH_API_BASE=http://10.0.2.2:8000
```

## Build a release APK
```bash
flutter build apk --release --dart-define=KAVACH_API_BASE=https://your-api.example.com
```

> `lib/l10n/app_localizations.dart` is **generated** by `flutter gen-l10n`
> (config in `l10n.yaml`); it is intentionally not committed.

## Adding a language
Drop `app_<code>.arb` into `lib/l10n/`, add the `Locale` to `supportedLocales`
in `main.dart`, and add it to the Settings language list. The backend already
serves 12 Indian languages via `/api/language/supported`.
