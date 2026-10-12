import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// API client for the Terrastep server — Blueprint Section 16 contracts.
/// In production this points at the Supabase-backed deployment of the same
/// contracts; the dev default is the Stage 2 reference server on localhost
/// (use `adb reverse tcp:8791 tcp:8791` on a device/emulator).
class ApiException implements Exception {
  ApiException(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
  @override
  String toString() => 'ApiException($status): ${body['error'] ?? body}';
}

class TerrastepApi {
  TerrastepApi({String? baseUrl})
      : baseUrl = baseUrl ??
            const String.fromEnvironment('TERRASTEP_API',
                defaultValue: 'http://127.0.0.1:8791');

  final String baseUrl;
  final _storage = const FlutterSecureStorage();
  String? _token;
  String? userId;

  Future<String?> restoreToken() async {
    _token = await _storage.read(key: 'auth_token');
    userId = await _storage.read(key: 'user_id');
    return _token;
  }

  Future<void> _saveToken(String token, String uid) async {
    _token = token;
    userId = uid;
    await _storage.write(key: 'auth_token', value: token);
    await _storage.write(key: 'user_id', value: uid);
  }

  Future<void> signOut() async {
    _token = null;
    userId = null;
    await _storage.delete(key: 'auth_token');
    await _storage.delete(key: 'user_id');
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Future<Map<String, dynamic>> _call(String method, String path,
      {Map<String, dynamic>? body, Map<String, String>? extraHeaders}) async {
    final uri = Uri.parse('$baseUrl$path');
    final req = http.Request(method, uri);
    req.headers.addAll(_headers);
    if (extraHeaders != null) req.headers.addAll(extraHeaders);
    if (body != null) req.body = jsonEncode(body);
    final streamed = await req.send();
    final text = await streamed.stream.bytesToString();
    final decoded = text.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(text) as Map<String, dynamic>;
    if (streamed.statusCode >= 400) {
      throw ApiException(streamed.statusCode, decoded);
    }
    return decoded;
  }

  // --- Auth (Section 16 lifecycle; Supabase Auth in production) ---
  Future<void> signUp(String email, String password, String nickname) =>
      _call('POST', '/v1/auth/signup',
          body: {'email': email, 'password': password, 'nickname': nickname});

  Future<void> logIn(String email, String password) async {
    final out = await _call('POST', '/v1/auth/login',
        body: {'email': email, 'password': password});
    await _saveToken(out['token'] as String, out['user_id'] as String);
  }

  // --- Sessions (Section 16) ---
  Future<Map<String, dynamic>> startSession(String? installationId) =>
      _call('POST', '/v1/sessions', body: {'installation_id': installationId});

  Future<Map<String, dynamic>> uploadBatch(
          String sessionId, String ticket, Map<String, dynamic> batch) =>
      _call('POST', '/v1/sessions/$sessionId/batches',
          body: batch, extraHeaders: {'X-Session-Ticket': ticket});

  Future<Map<String, dynamic>> finishSession(String sessionId) =>
      _call('POST', '/v1/sessions/$sessionId/finish', body: {});

  // --- Public projections (sanitized server-side, Sections 15/19) ---
  Future<Map<String, dynamic>> regionCells(double lat, double lng,
          {int k = 2}) =>
      _call('GET', '/v1/regions/abbottabad-pilot/cells?lat=$lat&lng=$lng&k=$k');

  Future<Map<String, dynamic>> leagueBoard() =>
      _call('GET', '/v1/leagues/abbottabad-pilot/board');

  // --- Private data (owner-only, Section 15) ---
  Future<Map<String, dynamic>> myActivities() =>
      _call('GET', '/v1/me/activities');

  Future<Map<String, dynamic>> patchProfile(Map<String, dynamic> fields) =>
      _call('PATCH', '/v1/me/profile', body: fields);

  Future<Map<String, dynamic>> addExclusion(double lat, double lng) =>
      _call('POST', '/v1/me/exclusions', body: {'lat': lat, 'lng': lng});

  Future<Map<String, dynamic>> report(Map<String, dynamic> body) =>
      _call('POST', '/v1/reports', body: body);

  Future<Map<String, dynamic>> exportData() =>
      _call('POST', '/v1/me/export', body: {});

  Future<Map<String, dynamic>> deleteAccount() => _call('DELETE', '/v1/me');
}
