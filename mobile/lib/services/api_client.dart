import 'package:dio/dio.dart';

import '../config.dart';

typedef Json = Map<String, dynamic>;

/// Thin typed wrapper over the Kavach REST API.
class ApiClient {
  final Dio _dio;

  ApiClient({String? baseUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? Config.apiBase,
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 60),
        ));

  void setToken(String? token) {
    if (token != null) {
      _dio.options.headers['Authorization'] = 'Bearer $token';
    } else {
      _dio.options.headers.remove('Authorization');
    }
  }

  Future<Json> _get(String path, [Map<String, dynamic>? q]) async =>
      Json.from((await _dio.get(path, queryParameters: q)).data);
  Future<Json> _post(String path, Object? body) async =>
      Json.from((await _dio.post(path, data: body)).data);

  // auth (demo backend; Supabase is used instead when configured)
  Future<Json> login(String email, String password) =>
      _post('/api/auth/login', {'email': email, 'password': password});
  Future<Json> register(String email, String password, String name) =>
      _post('/api/auth/register', {'email': email, 'password': password, 'name': name});

  // universe
  Future<Json> overview() => _get('/api/overview');
  Future<Json> sectors() => _get('/api/sectors');
  Future<Json> modelCard() => _get('/api/model');
  Future<Json> companies({int limit = 50, int offset = 0, String? band, String? sector, String? q, String sort = 'risk'}) =>
      _get('/api/companies', {
        'limit': limit, 'offset': offset, 'sort': sort,
        if (band != null) 'band': band, if (sector != null) 'sector': sector,
        if (q != null && q.isNotEmpty) 'q': q,
      });
  Future<List<Json>> search(String q, {int limit = 8}) async =>
      ((await _get('/api/companies/search', {'q': q, 'limit': limit}))['results'] as List).cast<Json>();
  Future<Json> company(String id) => _get('/api/companies/$id');

  // network
  Future<Json> egoGraph(String id, {int hops = 1}) => _get('/api/network/$id/graph', {'hops': hops});
  Future<Json> simulateFailure(String id, {int depth = 4}) async =>
      Json.from((await _dio.post('/api/network/$id/simulate-failure', queryParameters: {'max_depth': depth})).data);

  // scenario
  Future<Json> scenario(String id, {double revenueChange = 0, double rateChange = 0, double marginChange = 0,
          double debtChange = 0, bool supplierFailure = false, bool customerLoss = false}) =>
      _post('/api/scenario', {
        'company_id': id, 'revenue_change': revenueChange, 'interest_rate_change': rateChange,
        'margin_change': marginChange, 'debt_change': debtChange,
        'supplier_failure': supplierFailure, 'customer_loss': customerLoss,
      });
  Future<Json> sweep(String id) => _get('/api/scenario/$id/sweep');

  // portfolio / alerts
  Future<Json> portfolioRisk(List<Json> holdings) => _post('/api/portfolio/risk', {'holdings': holdings});
  Future<Json> earlyWarnings({double threshold = 0.10}) => _get('/api/alerts/early-warning', {'threshold': threshold});

  // analyze a real company
  Future<Json> analyzeTemplate() => _get('/api/analyze/template');
  Future<Json> analyze(Json payload) => _post('/api/analyze', payload);

  // assistant
  Future<Json> ask(String text, String lang) => _post('/api/assistant', {'text': text, 'lang': lang});

  // ---- real companies
  Future<Json> ticker(String symbol) => _get('/api/ingest/ticker/${Uri.encodeComponent(symbol)}');
  String get templateUrl => '${_dio.options.baseUrl}/api/ingest/template.csv';

  Future<Json> _upload(String path, List<int> bytes, String filename, [Map<String, dynamic> fields = const {}]) async {
    final form = FormData.fromMap({...fields, 'file': MultipartFile.fromBytes(bytes, filename: filename)});
    return Json.from((await _dio.post(path, data: form)).data);
  }

  Future<Json> parseTable(List<int> bytes, String filename, {String unit = 'crore'}) =>
      _upload('/api/ingest/table', bytes, filename, {'unit': unit});
  Future<Json> extractPdf(List<int> bytes, String filename) => _upload('/api/ingest/pdf', bytes, filename);
  Future<Json> scoreWorkspace(Json workspace) => _post('/api/workspace/score', workspace);
  Future<Json> retrain(Json workspace) => _post('/api/workspace/retrain', workspace);
}
