import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/inbox_enums.dart';
import 'connector.dart';

/// Reads a currently valid Google Calendar access token.
///
/// Supplied by the caller so this connector never stores or logs credentials
/// itself: the token lives wherever the app already keeps provider secrets, and
/// the connector only ever receives the short-lived access token.
typedef GoogleAccessTokenProvider = Future<String?> Function();

/// A Google Calendar connector over the public REST API.
///
/// Design notes:
///
/// - It talks to `https://www.googleapis.com/calendar/v3` directly with the
///   already-present `http` package rather than adding a Google SDK, matching the
///   repo's guidance to lean on existing dependencies.
/// - The long-running OAuth dance is deliberately *not* reimplemented here. The
///   app already has PKCE/loopback/token-refresh machinery for providers and MCP
///   (see `lib/core/services/auth/` and `docs/provider-oauth.md`); this class only
///   asks for an access token through [GoogleAccessTokenProvider].
/// - A write is only confirmed when Google returns an event `id`. The engine
///   treats anything else as unconfirmed, so a 2xx with an unparsable body can
///   never be reported as "created".
/// - Idempotency uses the event's `extendedProperties.private` slot plus the
///   calendar's `privateExtendedProperty` filter. That is what makes a retry
///   land on the existing event instead of creating a duplicate — the same
///   guarantee the demo connector gives, but against the real service.
class GoogleCalendarConnector implements ConnectorAccess {
  GoogleCalendarConnector({
    required this.accessToken,
    this.calendarId = 'primary',
    http.Client? httpClient,
    this.baseUrl = 'https://www.googleapis.com/calendar/v3',
  }) : _http = httpClient ?? http.Client();

  /// Returns a valid access token, or null when the user is not connected.
  final GoogleAccessTokenProvider accessToken;

  /// Google's calendar identifier; `primary` is the user's main calendar.
  final String calendarId;

  final String baseUrl;
  final http.Client _http;

  /// The private extended-property key that carries our idempotency key.
  static const idempotencyProperty = 'kelivoIdempotencyKey';

  @override
  ConnectorManifest get manifest => const ConnectorManifest(
    id: 'google_calendar',
    name: 'Google Calendar',
    version: '1',
    supportedEntities: {InboxEntityType.meeting},
    operations: {InboxOperation.create, InboxOperation.update},
    canSearch: true,
    canGet: true,
    requiresApproval: true,
  );

  @override
  Future<void> connect() async {
    // Nothing to establish: OAuth is owned by the auth layer. Fail fast when no
    // token is available so the UI can prompt the user instead of writing.
    final token = await accessToken();
    if (token == null || token.isEmpty) {
      throw StateError('google_calendar_not_authorized');
    }
  }

  @override
  Future<void> disconnect() async {
    // Credentials belong to the auth layer; dropping them is its job.
  }

  /// Finds events whose private extended property matches [idempotencyKey].
  Future<ConnectorRecord?> findByExtendedProperty(String idempotencyKey) async {
    final uri = Uri.parse('$baseUrl/calendars/$calendarId/events').replace(
      queryParameters: {
        'privateExtendedProperty': '$idempotencyProperty=$idempotencyKey',
        'maxResults': '1',
        'showDeleted': 'false',
      },
    );
    final response = await _send('GET', uri);
    final items = response['items'];
    if (items is! List || items.isEmpty) return null;
    final event = items.first as Map<String, dynamic>;
    final id = event['id'];
    if (id is! String || id.isEmpty) return null;
    return ConnectorRecord(externalId: id, fieldsJson: jsonEncode(event));
  }

  @override
  Future<List<ConnectorRecord>> search(
    InboxEntityType entityType,
    String query, {
    int limit = 20,
  }) async {
    final uri = Uri.parse('$baseUrl/calendars/$calendarId/events').replace(
      queryParameters: {
        'q': query,
        'maxResults': '$limit',
        'singleEvents': 'true',
        'orderBy': 'startTime',
      },
    );
    final response = await _send('GET', uri);
    final items = response['items'];
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map<String, dynamic> && item['id'] is String)
          ConnectorRecord(
            externalId: item['id'] as String,
            fieldsJson: jsonEncode(item),
          ),
    ];
  }

  @override
  Future<ConnectorRecord?> get(
    InboxEntityType entityType,
    String externalId,
  ) async {
    final uri = Uri.parse('$baseUrl/calendars/$calendarId/events/$externalId');
    try {
      final response = await _send('GET', uri);
      return ConnectorRecord(
        externalId: externalId,
        fieldsJson: jsonEncode(response),
      );
    } on ConnectorHttpException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Re-reads the event so a caller can confirm it still exists remotely.
  ///
  /// Returns null when the event is gone, which is a meaningful answer rather
  /// than a failure: the caller decides what a missing event means.
  @override
  Future<ConnectorRecord?> verify(String externalId) =>
      get(InboxEntityType.meeting, externalId);

  /// Creates or updates an event.
  ///
  /// The event body must already contain `summary` and `start`/`end` as Google
  /// expects. Requests are sent with [idempotencyKey] stamped into the private
  /// extended properties so a retried action can be recognised.
  @override
  Future<ConnectorWriteResult> execute(ConnectorWriteRequest request) async {
    if (!manifest.supports(request.entityType)) {
      return ConnectorWriteResult.failed(
        summary: 'unsupported entity ${request.entityType.storageValue}',
      );
    }
    if (!manifest.canPerform(request.operation)) {
      return ConnectorWriteResult.failed(
        summary: 'unsupported operation ${request.operation.storageValue}',
      );
    }

    final Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(request.fieldsJson);
      if (decoded is! Map<String, dynamic>) {
        return const ConnectorWriteResult.failed(
          summary: 'event fields must be a JSON object',
        );
      }
      body = Map<String, dynamic>.from(decoded);
    } on FormatException {
      return const ConnectorWriteResult.failed(
        summary: 'event fields are not valid JSON',
      );
    }

    _stampIdempotency(body, request.idempotencyKey);

    // Retry safety: look for an event this action already created.
    if (request.operation == InboxOperation.create) {
      final existing = await findByExtendedProperty(request.idempotencyKey);
      if (existing != null) {
        return ConnectorWriteResult.succeeded(
          externalId: existing.externalId,
          summary: 'idempotent replay, event already exists',
        );
      }
      final uri = Uri.parse('$baseUrl/calendars/$calendarId/events');
      final response = await _send('POST', uri, body: body);
      return _resultFromEvent(response);
    }

    final target = request.targetExternalId;
    if (target == null || target.isEmpty) {
      return const ConnectorWriteResult.failed(
        summary: 'update requires a target event id',
      );
    }
    final uri = Uri.parse('$baseUrl/calendars/$calendarId/events/$target');
    final response = await _send('PATCH', uri, body: body);
    return _resultFromEvent(response);
  }

  /// Stamps our key without disturbing other private properties.
  void _stampIdempotency(Map<String, dynamic> body, String key) {
    final existing = body['extendedProperties'];
    final props = existing is Map<String, dynamic>
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    final private = props['private'];
    final privateMap = private is Map<String, dynamic>
        ? Map<String, dynamic>.from(private)
        : <String, dynamic>{};
    privateMap[idempotencyProperty] = key;
    props['private'] = privateMap;
    body['extendedProperties'] = props;
  }

  ConnectorWriteResult _resultFromEvent(Map<String, dynamic> response) {
    final id = response['id'];
    if (id is! String || id.isEmpty) {
      // A 2xx without an id means we cannot point at what was written.
      return const ConnectorWriteResult.failed(
        summary: 'calendar returned no event id',
      );
    }
    return ConnectorWriteResult.succeeded(
      externalId: id,
      summary: 'event written',
    );
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    final token = await accessToken();
    if (token == null || token.isEmpty) {
      throw const ConnectorHttpException(
        statusCode: 401,
        message: 'google_calendar_not_authorized',
      );
    }
    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
    };

    final http.Response response;
    try {
      switch (method) {
        case 'POST':
          response = await _http.post(
            uri,
            headers: headers,
            body: jsonEncode(body),
          );
        case 'PATCH':
          response = await _http.patch(
            uri,
            headers: headers,
            body: jsonEncode(body),
          );
        default:
          response = await _http.get(uri, headers: headers);
      }
    } on TimeoutException {
      throw const ConnectorHttpException(
        statusCode: 0,
        message: 'google_calendar_timeout',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ConnectorHttpException(
        statusCode: response.statusCode,
        // Deliberately short: never echo a request body that may contain
        // personal calendar text into logs.
        message: 'google_calendar_http_${response.statusCode}',
      );
    }
    if (response.body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      throw const ConnectorHttpException(
        statusCode: 0,
        message: 'google_calendar_bad_response',
      );
    }
  }

  void close() => _http.close();
}
