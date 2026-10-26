# Kavach Web (Flutter)

The primary analyst experience for Kavach: a responsive web application for desktop
and mobile browsers, served by the same deployment as the FastAPI backend. The
project's existing Android target remains available, but web is the supported
production client.

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

## Run locally
```bash
flutter pub get
# point the browser client at your local backend:
flutter run -d chrome --dart-define=KAVACH_API_BASE=http://localhost:8010
```

## Build the web client
```bash
flutter build web --release
```

The Render Docker deployment builds the web client and serves it at `/`, with the
API available under `/api` on the same origin. No production API URL is compiled
into the browser bundle.

## Adding a language
Add the language to the `languages` list and English strings to `strings.dart`;
add translated values to the appropriate `translations_*.dart` map. The Settings
language grid is built from that list. The backend also serves 12 Indian
languages via `/api/language/supported`.
