import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:Kelivo/core/models/inbox_enums.dart';
import 'package:Kelivo/core/services/inbox/connector.dart';
import 'package:Kelivo/core/services/inbox/google_calendar_connector.dart';

/// A scripted backend standing in for the Google Calendar REST API.
///
/// It records requests so tests can assert what was actually sent, and it can be
/// told to fail, which is how the honest-failure paths get exercised without a
/// network or a real Google account.
class FakeCalendarBackend {
  FakeCalendarBackend();

  final List<http.Request> requests = [];
  final Map<String, Map<String, dynamic>> events = {};
  final Map<String, String> idempotencyToEvent = {};

  int? forcedStatus;
  String? forcedBody;
  bool omitIdFromCreate = false;
  int sequence = 0;

  http.Client get client => MockClient((request) async {
    requests.add(request);

    if (forcedStatus != null) {
      return http.Response(forcedBody ?? '{}', forcedStatus!);
    }

    final uri = request.url;
    final path = uri.path;

    if (request.method == 'GET' && path.endsWith('/events')) {
      final property = uri.queryParameters['privateExtendedProperty'];
      if (property != null && property.contains('=')) {
        final key = property.split('=').last;
        final eventId = idempotencyToEvent[key];
        final event = eventId == null ? null : events[eventId];
        return http.Response(
          jsonEncode({
            'items': event == null ? [] : [event],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      final query = uri.queryParameters['q']?.toLowerCase();
      final matches = events.values.where((event) {
        if (query == null || query.isEmpty) return true;
        final summary = (event['summary'] as String? ?? '').toLowerCase();
        return summary.contains(query);
      }).toList();
      return http.Response(
        jsonEncode({'items': matches}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    if (request.method == 'POST' && path.endsWith('/events')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final eventId = 'evt-${++sequence}';
      events[eventId] = {...body, 'id': eventId};
      final private = (body['extendedProperties'] as Map?)?['private'] as Map?;
      final key = private?['kelivoIdempotencyKey'] as String?;
      if (key != null) idempotencyToEvent[key] = eventId;
      if (omitIdFromCreate) {
        return http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode(events[eventId]),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    if (request.method == 'PATCH') {
      final eventId = path.split('/').last;
      final existing = events[eventId];
      if (existing == null) return http.Response('{}', 404);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      events[eventId] = {...existing, ...body, 'id': eventId};
      return http.Response(
        jsonEncode(events[eventId]),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    if (request.method == 'GET' && path.contains('/events/')) {
      final eventId = path.split('/').last;
      final event = events[eventId];
      if (event == null) return http.Response('{}', 404);
      return http.Response(
        jsonEncode(event),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    return http.Response('{}', 404);
  });
}

void main() {
  late FakeCalendarBackend backend;
  late GoogleCalendarConnector connector;

  setUp(() async {
    backend = FakeCalendarBackend();
    connector = GoogleCalendarConnector(
      accessToken: () async => 'test-token',
      httpClient: backend.client,
    );
    await connector.connect();
  });

  http.Request lastPost() =>
      backend.requests.lastWhere((r) => r.method == 'POST');

  ConnectorWriteRequest createRequest({
    String key = 'key-1',
    String fields =
        '{"summary":"融资方案评审","start":{"dateTime":"2026-11-13T17:00:00+04:00"},"end":{"dateTime":"2026-11-13T18:00:00+04:00"}}',
  }) {
    return ConnectorWriteRequest(
      actionId: 'a-1',
      entityType: InboxEntityType.meeting,
      operation: InboxOperation.create,
      fieldsJson: fields,
      idempotencyKey: key,
    );
  }

  group('manifest', () {
    test('declares only what it can actually do', () {
      final manifest = connector.manifest;
      expect(manifest.id, 'google_calendar');
      expect(manifest.supportedEntities, {InboxEntityType.meeting});
      expect(manifest.operations, {
        InboxOperation.create,
        InboxOperation.update,
      });
      expect(manifest.canDetectDuplicates, isTrue);
    });
  });

  group('create', () {
    test('sends the token and returns the real event id', () async {
      final result = await connector.execute(createRequest());

      expect(result.isConfirmed, isTrue);
      expect(result.externalId, 'evt-1');
      // A create first searches by idempotency key, then posts.
      final sent = lastPost();
      expect(sent.headers['Authorization'], 'Bearer test-token');
      expect(sent.url.path, endsWith('/calendars/primary/events'));
    });

    test(
      'stamps the idempotency key into private extended properties',
      () async {
        await connector.execute(createRequest(key: 'stable-abc'));

        final body = jsonDecode(lastPost().body) as Map<String, dynamic>;
        final private = (body['extendedProperties'] as Map)['private'] as Map;
        expect(
          private[GoogleCalendarConnector.idempotencyProperty],
          'stable-abc',
        );
      },
    );

    test(
      'a retried action reuses the existing event instead of duplicating',
      () async {
        final first = await connector.execute(createRequest(key: 'same-key'));
        final second = await connector.execute(createRequest(key: 'same-key'));

        expect(first.externalId, second.externalId);
        expect(second.summary, contains('already exists'));
        expect(backend.events, hasLength(1));
        // Only one POST; the replay is answered by the search.
        expect(backend.requests.where((r) => r.method == 'POST'), hasLength(1));
      },
    );

    test('a 2xx without an event id is not treated as written', () async {
      backend.omitIdFromCreate = true;
      final result = await connector.execute(createRequest());

      expect(result.isConfirmed, isFalse);
      expect(result.summary, contains('no event id'));
    });

    test('a 401 surfaces as a transport error needing authorization', () async {
      backend.forcedStatus = 401;
      await expectLater(
        connector.execute(createRequest()),
        throwsA(
          isA<ConnectorHttpException>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
    });

    test('rejects non-object fields without calling the network', () async {
      final result = await connector.execute(
        createRequest(fields: '"just a string"'),
      );

      expect(result.isConfirmed, isFalse);
      expect(backend.requests, isEmpty);
    });

    test(
      'preserves the supplied timezone offset in the request body',
      () async {
        await connector.execute(createRequest());
        final body = jsonDecode(lastPost().body) as Map<String, dynamic>;
        final start = body['start'] as Map<String, dynamic>;
        expect(start['dateTime'], '2026-11-13T17:00:00+04:00');
      },
    );
  });

  group('update', () {
    test('patches the target event and returns its id', () async {
      await connector.execute(createRequest());
      final update = ConnectorWriteRequest(
        actionId: 'a-2',
        entityType: InboxEntityType.meeting,
        operation: InboxOperation.update,
        fieldsJson: '{"summary":"改期"}',
        idempotencyKey: 'key-2',
        targetExternalId: 'evt-1',
      );

      final result = await connector.execute(update);
      expect(result.externalId, 'evt-1');
      expect(backend.requests.last.method, 'PATCH');
    });

    test('refuses an update without a target id', () async {
      final result = await connector.execute(
        ConnectorWriteRequest(
          actionId: 'a-3',
          entityType: InboxEntityType.meeting,
          operation: InboxOperation.update,
          fieldsJson: '{"summary":"x"}',
          idempotencyKey: 'key-3',
        ),
      );

      expect(result.isConfirmed, isFalse);
      expect(result.summary, contains('target event id'));
    });
  });

  group('read-back', () {
    test('verify returns the event when it exists', () async {
      await connector.execute(createRequest());
      final record = await connector.verify('evt-1');
      expect(record, isNotNull);
      expect(record!.externalId, 'evt-1');
    });

    test('verify returns null for a missing event', () async {
      expect(await connector.verify('nope'), isNull);
    });

    test('search returns matching events', () async {
      await connector.execute(createRequest());
      final results = await connector.search(InboxEntityType.meeting, '融资');
      expect(results, hasLength(1));
    });
  });

  test('connect fails fast when no token is available', () async {
    final unauthorized = GoogleCalendarConnector(
      accessToken: () async => null,
      httpClient: backend.client,
    );
    await expectLater(unauthorized.connect(), throwsA(isA<StateError>()));
  });
}
