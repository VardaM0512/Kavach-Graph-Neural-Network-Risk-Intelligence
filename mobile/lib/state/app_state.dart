import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/api_client.dart';

/// Global app state: auth token, current user, and selected locale.
class AppState extends ChangeNotifier {
  final ApiClient api;
  final _storage = const FlutterSecureStorage();

  AppState(this.api);

  bool _authed = false;
  Map<String, dynamic>? _user;
  Locale _locale = const Locale('en');

  bool get isAuthenticated => _authed;
  Map<String, dynamic>? get user => _user;
  Locale get locale => _locale;

  Future<void> bootstrap() async {
    final token = await _storage.read(key: 'token');
    if (token != null && token.isNotEmpty) {
      api.setToken(token);
      _authed = true;
    }
    final lang = await _storage.read(key: 'lang');
    if (lang != null) _locale = Locale(lang);
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    final res = await api.login(email, password);
    final token = res['access_token'] as String;
    api.setToken(token);
    await _storage.write(key: 'token', value: token);
    _user = Map<String, dynamic>.from(res['user'] ?? {});
    _authed = true;
    notifyListeners();
  }

  Future<void> logout() async {
    await _storage.delete(key: 'token');
    api.setToken(null);
    _authed = false;
    _user = null;
    notifyListeners();
  }

  Future<void> setLocale(String code) async {
    _locale = Locale(code);
    await _storage.write(key: 'lang', value: code);
    notifyListeners();
  }
}
