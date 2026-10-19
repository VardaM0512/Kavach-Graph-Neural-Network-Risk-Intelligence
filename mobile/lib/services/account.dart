import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_client.dart';

class KUser {
  final String id, email, name;
  const KUser(this.id, this.email, this.name);
}

class WatchItem {
  final String companyId, name;
  final double threshold;
  final double? pdAtAdd;
  const WatchItem(this.companyId, this.name, {this.threshold = 0.10, this.pdAtAdd});
  Json toJson() => {'company_id': companyId, 'company_name': name, 'alert_threshold': threshold, 'pd_at_add': pdAtAdd};
  factory WatchItem.fromJson(Json j) => WatchItem(j['company_id'], j['company_name'] ?? j['company_id'],
      threshold: (j['alert_threshold'] as num?)?.toDouble() ?? 0.10, pdAtAdd: (j['pd_at_add'] as num?)?.toDouble());
}

class Holding {
  final String companyId, name;
  final double weight;
  const Holding(this.companyId, this.name, this.weight);
  Holding withWeight(double w) => Holding(companyId, name, w);
  Json toJson() => {'company_id': companyId, 'company_name': name, 'weight': weight};
  factory Holding.fromJson(Json j) => Holding(j['company_id'], j['company_name'] ?? j['company_id'], (j['weight'] as num).toDouble());
}

class SavedAnalysis {
  final String id, name;
  final String? sector;
  final double pd;
  final String band, rating;
  final DateTime createdAt;
  final Json input, result;
  const SavedAnalysis(this.id, this.name, this.sector, this.pd, this.band, this.rating, this.createdAt, this.input, this.result);
  factory SavedAnalysis.fromJson(Json j) => SavedAnalysis(
        '${j['id']}', j['company_name'], j['sector'], (j['pd_12m'] as num).toDouble(), j['risk_band'],
        j['implied_rating'] ?? '', DateTime.tryParse('${j['created_at']}') ?? DateTime.now(),
        Json.from(j['input'] ?? {}), Json.from(j['result'] ?? {}));
}

/// A real company in the user's workspace: statements for one or more fiscal years.
class WsCompany {
  final String name;
  final String? sector;
  final double promoterPledge;
  final int? defaulted;          // 1 known default, 0 known not, null unknown
  final List<Json> years;        // [{year, revenue, ebitda, ...}] INR crore
  final String source;           // upload | ticker | pdf | manual
  const WsCompany(this.name, this.sector, this.years, {this.promoterPledge = 0, this.defaulted, this.source = 'manual'});

  WsCompany copyWith({int? defaulted, bool clearDefault = false, List<Json>? years, String? sector}) =>
      WsCompany(name, sector ?? this.sector, years ?? this.years, promoterPledge: promoterPledge,
          defaulted: clearDefault ? null : (defaulted ?? this.defaulted), source: source);

  int get latestYear => years.map((y) => (y['year'] as num).toInt()).reduce((a, b) => a > b ? a : b);
  Json get latest => years.firstWhere((y) => (y['year'] as num).toInt() == latestYear);

  Json toApi() => {'name': name, 'sector': sector, 'promoter_pledge': promoterPledge, 'defaulted': defaulted,
        'years': [for (final y in years) Json.from(y)]};
  Json toRow() => {'company_name': name, 'sector': sector, 'promoter_pledge': promoterPledge,
        'defaulted': defaulted, 'years': years, 'source': source};
  factory WsCompany.fromRow(Json j) => WsCompany(j['company_name'] ?? j['name'], j['sector'],
      ((j['years'] as List?) ?? []).map((e) => Json.from(e)).toList(),
      promoterPledge: ((j['promoter_pledge'] as num?) ?? 0).toDouble(), defaulted: (j['defaulted'] as num?)?.toInt(),
      source: j['source'] ?? 'manual');
}

class WsLink {
  final String company, counterparty, relation, health;
  final double share;
  const WsLink(this.company, this.counterparty, this.relation, this.share, {this.health = 'stable'});
  Json toApi() => {'company': company, 'counterparty': counterparty, 'relation': relation, 'share': share, 'health': health};
  Json toRow() => toApi();
  factory WsLink.fromRow(Json j) => WsLink(j['company'], j['counterparty'], j['relation'] ?? 'customer',
      ((j['share'] as num?) ?? 0.2).toDouble(), health: j['health'] ?? 'stable');
}

class SignUpResult {
  final KUser? user;
  final bool needsConfirmation;
  const SignUpResult(this.user, this.needsConfirmation);
}

/// Accounts + per-user data. Two implementations share this contract.
abstract class AccountBackend {
  bool get isSupabase;
  Future<KUser?> restore();
  Future<KUser> signIn(String email, String password);
  Future<SignUpResult> signUp(String email, String password, {required String name, String? org, String? role, String lang = 'en'});
  Future<void> resetPassword(String email);
  Future<void> signOut();
  Future<void> updatePreferences({String? lang, String? theme});

  Future<List<WatchItem>> watchlist();
  Future<void> watch(WatchItem item);
  Future<void> unwatch(String companyId);

  Future<List<Holding>> holdings();
  Future<void> saveHoldings(List<Holding> holdings);

  Future<List<SavedAnalysis>> analyses();
  Future<void> saveAnalysis(Json input, Json result);
  Future<void> deleteAnalysis(String id);

  Future<void> logQuery(String question, String? intent, String? answer, String lang, bool voice);

  Future<(List<WsCompany>, List<WsLink>)> workspace();
  Future<void> saveWorkspace(List<WsCompany> companies, List<WsLink> links);
}

// ---------------------------------------------------------------- Supabase
class SupabaseBackend implements AccountBackend {
  SupabaseClient get _sb => Supabase.instance.client;
  static const _portfolioName = 'My portfolio';

  @override
  bool get isSupabase => true;

  KUser _user(User u) => KUser(u.id, u.email ?? '', (u.userMetadata?['full_name'] as String?) ?? (u.email ?? '').split('@').first);

  @override
  Future<KUser?> restore() async {
    final u = _sb.auth.currentUser;
    return u == null ? null : _user(u);
  }

  @override
  Future<KUser> signIn(String email, String password) async {
    final r = await _sb.auth.signInWithPassword(email: email, password: password);
    return _user(r.user!);
  }

  @override
  Future<SignUpResult> signUp(String email, String password,
      {required String name, String? org, String? role, String lang = 'en'}) async {
    final r = await _sb.auth.signUp(email: email, password: password, data: {
      'full_name': name, if (org != null) 'organisation': org, if (role != null) 'role': role, 'preferred_language': lang,
    });
    if (r.session == null) return const SignUpResult(null, true);   // email confirmation on
    return SignUpResult(_user(r.user!), false);
  }

  @override
  Future<void> resetPassword(String email) => _sb.auth.resetPasswordForEmail(email);

  @override
  Future<void> signOut() => _sb.auth.signOut();

  @override
  Future<void> updatePreferences({String? lang, String? theme}) async {
    final u = _sb.auth.currentUser;
    if (u == null) return;
    await _sb.from('profiles').update({
      if (lang != null) 'preferred_language': lang, if (theme != null) 'theme': theme,
    }).eq('id', u.id);
  }

  @override
  Future<List<WatchItem>> watchlist() async =>
      (await _sb.from('watchlist').select().order('created_at', ascending: false)).map(WatchItem.fromJson).toList();

  @override
  Future<void> watch(WatchItem item) => _sb.from('watchlist').upsert(item.toJson(), onConflict: 'user_id,company_id');

  @override
  Future<void> unwatch(String companyId) => _sb.from('watchlist').delete().eq('company_id', companyId);

  Future<String> _portfolioId() async {
    final rows = await _sb.from('portfolios').select('id').eq('name', _portfolioName).limit(1);
    if (rows.isNotEmpty) return rows.first['id'] as String;
    final ins = await _sb.from('portfolios').insert({'name': _portfolioName}).select('id').single();
    return ins['id'] as String;
  }

  @override
  Future<List<Holding>> holdings() async {
    final pid = await _portfolioId();
    return (await _sb.from('portfolio_holdings').select().eq('portfolio_id', pid)).map(Holding.fromJson).toList();
  }

  @override
  Future<void> saveHoldings(List<Holding> holdings) async {
    final pid = await _portfolioId();
    await _sb.from('portfolio_holdings').delete().eq('portfolio_id', pid);
    if (holdings.isNotEmpty) {
      await _sb.from('portfolio_holdings').insert([for (final h in holdings) {...h.toJson(), 'portfolio_id': pid}]);
    }
  }

  @override
  Future<List<SavedAnalysis>> analyses() async =>
      (await _sb.from('analyses').select().order('created_at', ascending: false).limit(50)).map(SavedAnalysis.fromJson).toList();

  @override
  Future<void> saveAnalysis(Json input, Json result) => _sb.from('analyses').insert(_analysisRow(input, result));

  @override
  Future<void> deleteAnalysis(String id) => _sb.from('analyses').delete().eq('id', id);

  @override
  Future<(List<WsCompany>, List<WsLink>)> workspace() async {
    final c = await _sb.from('workspace_companies').select().order('created_at');
    final l = await _sb.from('workspace_links').select();
    return (c.map(WsCompany.fromRow).toList(), l.map(WsLink.fromRow).toList());
  }

  @override
  Future<void> saveWorkspace(List<WsCompany> companies, List<WsLink> links) async {
    final uid = _sb.auth.currentUser!.id;
    await _sb.from('workspace_links').delete().eq('user_id', uid);
    await _sb.from('workspace_companies').delete().eq('user_id', uid);
    if (companies.isNotEmpty) await _sb.from('workspace_companies').insert([for (final c in companies) c.toRow()]);
    if (links.isNotEmpty) await _sb.from('workspace_links').insert([for (final l in links) l.toRow()]);
  }

  @override
  Future<void> logQuery(String question, String? intent, String? answer, String lang, bool voice) async {
    try {
      await _sb.from('assistant_queries').insert(
          {'question': question, 'intent': intent, 'answer': answer, 'lang': lang, 'via_voice': voice});
    } catch (_) {/* history is best-effort */}
  }
}

Json _analysisRow(Json input, Json result) => {
      'company_name': input['name'] ?? 'Unnamed company',
      'sector': input['sector'],
      'fiscal_year': input['fiscal_year'],
      'input': input,
      'result': result,
      'pd_12m': result['distress_probability'],
      'risk_band': result['risk_band'],
      'implied_rating': result['implied_rating'],
    };

// ------------------------------------------------------- local / demo mode
class LocalBackend implements AccountBackend {
  final ApiClient api;
  LocalBackend(this.api);
  SharedPreferences? _p;
  Future<SharedPreferences> get _prefs async => _p ??= await SharedPreferences.getInstance();
  String _uid = 'local';

  String _k(String name) => 'kavach.$_uid.$name';

  @override
  bool get isSupabase => false;

  @override
  Future<KUser?> restore() async {
    final p = await _prefs;
    final raw = p.getString('kavach.session');
    if (raw == null) return null;
    final j = jsonDecode(raw);
    api.setToken(j['token']);
    _uid = j['email'];
    return KUser(j['email'], j['email'], j['name'] ?? j['email']);
  }

  Future<KUser> _session(Json res) async {
    final u = Json.from(res['user'] ?? {});
    final email = u['email'] as String;
    api.setToken(res['access_token']);
    _uid = email;
    (await _prefs).setString('kavach.session',
        jsonEncode({'token': res['access_token'], 'email': email, 'name': u['name'] ?? email.split('@').first}));
    return KUser(email, email, (u['name'] as String?) ?? email.split('@').first);
  }

  @override
  Future<KUser> signIn(String email, String password) async => _session(await api.login(email, password));

  @override
  Future<SignUpResult> signUp(String email, String password,
          {required String name, String? org, String? role, String lang = 'en'}) async =>
      SignUpResult(await _session(await api.register(email, password, name)), false);

  @override
  Future<void> resetPassword(String email) async {}

  @override
  Future<void> signOut() async {
    (await _prefs).remove('kavach.session');
    api.setToken(null);
    _uid = 'local';
  }

  @override
  Future<void> updatePreferences({String? lang, String? theme}) async {}

  Future<List<Json>> _list(String name) async {
    final raw = (await _prefs).getString(_k(name));
    return raw == null ? [] : (jsonDecode(raw) as List).cast<Map>().map(Json.from).toList();
  }

  Future<void> _put(String name, List<Json> rows) async => (await _prefs).setString(_k(name), jsonEncode(rows));

  @override
  Future<List<WatchItem>> watchlist() async => (await _list('watchlist')).map(WatchItem.fromJson).toList();

  @override
  Future<void> watch(WatchItem item) async {
    final rows = (await _list('watchlist')).where((r) => r['company_id'] != item.companyId).toList();
    await _put('watchlist', [item.toJson(), ...rows]);
  }

  @override
  Future<void> unwatch(String companyId) async =>
      _put('watchlist', (await _list('watchlist')).where((r) => r['company_id'] != companyId).toList());

  @override
  Future<List<Holding>> holdings() async => (await _list('holdings')).map(Holding.fromJson).toList();

  @override
  Future<void> saveHoldings(List<Holding> holdings) => _put('holdings', [for (final h in holdings) h.toJson()]);

  @override
  Future<List<SavedAnalysis>> analyses() async => (await _list('analyses')).map(SavedAnalysis.fromJson).toList();

  @override
  Future<void> saveAnalysis(Json input, Json result) async {
    final row = {..._analysisRow(input, result), 'id': DateTime.now().microsecondsSinceEpoch,
      'created_at': DateTime.now().toIso8601String()};
    await _put('analyses', [row, ...await _list('analyses')]);
  }

  @override
  Future<void> deleteAnalysis(String id) async =>
      _put('analyses', (await _list('analyses')).where((r) => '${r['id']}' != id).toList());

  @override
  Future<void> logQuery(String question, String? intent, String? answer, String lang, bool voice) async {}

  @override
  Future<(List<WsCompany>, List<WsLink>)> workspace() async =>
      ((await _list('ws_companies')).map(WsCompany.fromRow).toList(), (await _list('ws_links')).map(WsLink.fromRow).toList());

  @override
  Future<void> saveWorkspace(List<WsCompany> companies, List<WsLink> links) async {
    await _put('ws_companies', [for (final c in companies) c.toRow()]);
    await _put('ws_links', [for (final l in links) l.toRow()]);
  }
}
