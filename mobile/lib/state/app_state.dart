import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/account.dart';
import '../services/api_client.dart';

/// Global app state: session, language, theme, watchlist and portfolio.
class AppState extends ChangeNotifier {
  final ApiClient api;
  final AccountBackend account;

  AppState(this.api, this.account);

  bool ready = false;
  KUser? user;
  String lang = 'en';
  ThemeMode themeMode = ThemeMode.dark;
  List<WatchItem> watchlist = [];
  List<Holding> holdings = [];
  List<WsCompany> workspace = [];
  List<WsLink> links = [];

  bool get isAuthenticated => user != null;

  Future<void> bootstrap() async {
    final p = await SharedPreferences.getInstance();
    lang = p.getString('kavach.lang') ?? 'en';
    themeMode = p.getString('kavach.theme') == 'light' ? ThemeMode.light : ThemeMode.dark;
    try {
      user = await account.restore();
      if (user != null) await _loadUserData();
    } catch (_) {
      user = null;
    }
    ready = true;
    notifyListeners();
  }

  Future<void> _loadUserData() async {
    try {
      watchlist = await account.watchlist();
      holdings = await account.holdings();
      final ws = await account.workspace();
      workspace = ws.$1;
      links = ws.$2;
    } catch (_) {/* tables may not exist yet; keep empty */}
  }

  Future<void> signIn(String email, String password) async {
    user = await account.signIn(email, password);
    await _loadUserData();
    notifyListeners();
  }

  /// Returns true when the user must confirm their email first.
  Future<bool> signUp(String email, String password, {required String name, String? org, String? role}) async {
    final r = await account.signUp(email, password, name: name, org: org, role: role, lang: lang);
    if (r.user != null) {
      user = r.user;
      await _loadUserData();
      notifyListeners();
    }
    return r.needsConfirmation;
  }

  Future<void> signOut() async {
    await account.signOut();
    user = null;
    watchlist = [];
    holdings = [];
    workspace = [];
    links = [];
    notifyListeners();
  }

  Future<void> setLang(String code) async {
    lang = code;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString('kavach.lang', code);
    if (user != null) account.updatePreferences(lang: code).catchError((_) {});
  }

  Future<void> setTheme(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    final name = mode == ThemeMode.light ? 'light' : 'dark';
    (await SharedPreferences.getInstance()).setString('kavach.theme', name);
    if (user != null) account.updatePreferences(theme: name).catchError((_) {});
  }

  // ---- watchlist
  bool isWatched(String id) => watchlist.any((w) => w.companyId == id);

  Future<void> toggleWatch(String id, String name, double pd) async {
    if (isWatched(id)) {
      watchlist.removeWhere((w) => w.companyId == id);
      notifyListeners();
      await account.unwatch(id);
    } else {
      final item = WatchItem(id, name, pdAtAdd: pd);
      watchlist.insert(0, item);
      notifyListeners();
      await account.watch(item);
    }
  }

  // ---- workspace (the user's real companies)
  /// Add or merge companies: same name -> fiscal years are merged (newer upload wins).
  Future<void> addCompanies(List<WsCompany> add, [List<WsLink> newLinks = const []]) async {
    for (final c in add) {
      final i = workspace.indexWhere((w) => w.name.toLowerCase() == c.name.toLowerCase());
      if (i < 0) {
        workspace.add(c);
      } else {
        final years = {for (final y in workspace[i].years) (y['year'] as num).toInt(): y};
        for (final y in c.years) {
          years[(y['year'] as num).toInt()] = y;
        }
        workspace[i] = workspace[i].copyWith(years: years.values.toList(), sector: c.sector, defaulted: c.defaulted);
      }
    }
    for (final l in newLinks) {
      links.removeWhere((x) => x.company.toLowerCase() == l.company.toLowerCase() &&
          x.counterparty.toLowerCase() == l.counterparty.toLowerCase());
      links.add(l);
    }
    notifyListeners();
    await account.saveWorkspace(workspace, links);
  }

  Future<void> removeCompany(String name) async {
    workspace.removeWhere((w) => w.name == name);
    links.removeWhere((l) => l.company == name || l.counterparty == name);
    notifyListeners();
    await account.saveWorkspace(workspace, links);
  }

  Future<void> setDefaulted(String name, int? value) async {
    final i = workspace.indexWhere((w) => w.name == name);
    if (i < 0) return;
    workspace[i] = workspace[i].copyWith(defaulted: value, clearDefault: value == null);
    notifyListeners();
    await account.saveWorkspace(workspace, links);
  }

  Json get workspacePayload => {
        'companies': [for (final c in workspace) c.toApi()],
        'relationships': [for (final l in links) l.toApi()],
      };

  // ---- portfolio
  Future<void> setHoldings(List<Holding> h) async {
    holdings = h;
    notifyListeners();
    await account.saveHoldings(h);
  }
}
