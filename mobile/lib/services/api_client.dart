import 'package:dio/dio.dart';

/// Thin wrapper over Dio for the Kavach REST API.
///
/// Base URL resolves in this order:
///   --dart-define=KAVACH_API_BASE=https://api.example.com   (build-time)
///   http://10.0.2.2:8000  (Android emulator -> host localhost)
class ApiClient {
  final Dio _dio;
  String? _token;

  ApiClient({String? baseUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl ??
              const String.fromEnvironment('KAVACH_API_BASE',
                  defaultValue: 'http://10.0.2.2:8000'),
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 30),
        ));

  void setToken(String? token) {
    _token = token;
    if (token != null) {
      _dio.options.headers['Authorization'] = 'Bearer $token';
    } else {
      _dio.options.headers.remove('Authorization');
    }
  }

  bool get hasToken => _token != null;

  // ---- auth ----
  Future<Map<String, dynamic>> login(String email, String password) async {
    final r = await _dio.post('/api/auth/login',
        data: {'email': email, 'password': password});
    return Map<String, dynamic>.from(r.data);
  }

  // ---- companies ----
  Future<List<dynamic>> companies({int limit = 50, String? band}) async {
    final r = await _dio.get('/api/companies',
        queryParameters: {'limit': limit, if (band != null) 'band': band});
    return r.data['companies'] as List<dynamic>;
  }

  Future<Map<String, dynamic>> company(String id) async =>
      Map<String, dynamic>.from((await _dio.get('/api/companies/$id')).data);

  // ---- predictions ----
  Future<Map<String, dynamic>> predict(String id) async =>
      Map<String, dynamic>.from((await _dio.get('/api/predictions/$id')).data);

  // ---- network ----
  Future<Map<String, dynamic>> egoGraph(String id, {int hops = 1}) async =>
      Map<String, dynamic>.from(
          (await _dio.get('/api/network/$id/graph', queryParameters: {'hops': hops}))
              .data);

  Future<Map<String, dynamic>> contagion(String id) async =>
      Map<String, dynamic>.from((await _dio.get('/api/network/$id/contagion')).data);

  Future<Map<String, dynamic>> simulateFailure(String id) async =>
      Map<String, dynamic>.from(
          (await _dio.post('/api/network/$id/simulate-failure')).data);

  Future<Map<String, dynamic>> heatmap() async =>
      Map<String, dynamic>.from((await _dio.get('/api/network/heatmap')).data);

  // ---- explain / scenario / portfolio / alerts ----
  Future<Map<String, dynamic>> explain(String id, {String lang = 'en'}) async =>
      Map<String, dynamic>.from(
          (await _dio.get('/api/explain/$id', queryParameters: {'lang': lang})).data);

  Future<Map<String, dynamic>> scenario(String id,
      {double revenueChange = 0,
      double rateChange = 0,
      bool supplierFailure = false}) async {
    final r = await _dio.post('/api/scenario', data: {
      'company_id': id,
      'revenue_change': revenueChange,
      'interest_rate_change': rateChange,
      'supplier_failure': supplierFailure,
    });
    return Map<String, dynamic>.from(r.data);
  }

  Future<Map<String, dynamic>> portfolioRisk(List<Map<String, dynamic>> holdings) async {
    final r = await _dio.post('/api/portfolio/risk', data: {'holdings': holdings});
    return Map<String, dynamic>.from(r.data);
  }

  Future<Map<String, dynamic>> earlyWarnings({double threshold = 0.6}) async =>
      Map<String, dynamic>.from((await _dio
              .get('/api/alerts/early-warning', queryParameters: {'threshold': threshold}))
          .data);

  // ---- language / voice ----
  Future<List<dynamic>> languages() async =>
      (await _dio.get('/api/language/supported')).data['languages'] as List<dynamic>;

  Future<Map<String, dynamic>> tts(String text, String lang) async {
    final r = await _dio.post('/api/voice/tts', data: {'text': text, 'lang': lang});
    return Map<String, dynamic>.from(r.data);
  }
}
