import 'dart:async';

import '../../models/inbox_enums.dart';
import 'connector.dart';

/// An in-memory connector used to exercise the execution loop end to end.
///
/// The design sanctions a built-in demo connector (§2 P0: "第三个可使用内置演示
/// Connector 验证 CRM 字段变更"). It exists so approval, idempotency, receipts and
/// honest failure can be tested without an external account, and it never
/// claims a write it did not perform:
///
/// - it records exactly one remote object per [ConnectorWriteRequest.idempotencyKey],
///   so a retried action updates instead of creating a duplicate;
/// - an unsupported entity or operation returns a failure, not a fabricated id;
/// - [failNextWrites] injects a failure so callers can prove they do not report
///   success when the connector errors.
class DemoConnector implements ConnectorAccess {
  DemoConnector({Set<InboxEntityType>? entities})
    : _entities =
          entities ??
          const {
            InboxEntityType.contact,
            InboxEntityType.opportunity,
            InboxEntityType.funding,
            InboxEntityType.meeting,
            InboxEntityType.task,
            InboxEntityType.note,
          };

  final Set<InboxEntityType> _entities;

  final Map<String, ConnectorRecord> _records = {};

  /// Idempotency key -> external id of the object it produced.
  final Map<String, String> _byIdempotencyKey = {};

  int _sequence = 0;
  bool _connected = false;

  /// Number of upcoming [execute] calls that should fail.
  int failNextWrites = 0;

  /// When true, writes appear to succeed but report no identifier, which the
  /// engine must treat as unconfirmed rather than done.
  bool omitExternalIds = false;

  static const _externalIdPrefix = 'demo-';

  @override
  ConnectorManifest get manifest => ConnectorManifest(
    id: 'demo',
    name: 'Demo connector',
    version: '1',
    supportedEntities: _entities,
    operations: const {
      InboxOperation.create,
      InboxOperation.update,
      InboxOperation.append,
      InboxOperation.ignore,
    },
    canSearch: true,
    canGet: true,
    requiresApproval: true,
  );

  /// The records written so far, for assertions and the demo UI.
  List<ConnectorRecord> get records => List.unmodifiable(_records.values);

  @override
  Future<void> connect() async {
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<List<ConnectorRecord>> search(
    InboxEntityType entityType,
    String query, {
    int limit = 20,
  }) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return _records.values
        .where((record) => record.fieldsJson.toLowerCase().contains(needle))
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<ConnectorRecord?> get(
    InboxEntityType entityType,
    String externalId,
  ) async {
    return _records[externalId];
  }

  @override
  Future<ConnectorWriteResult> execute(ConnectorWriteRequest request) async {
    if (!_connected) {
      return const ConnectorWriteResult.failed(
        summary: 'connector is not connected',
      );
    }
    if (!_entities.contains(request.entityType)) {
      return ConnectorWriteResult.failed(
        summary: 'unsupported entity ${request.entityType.storageValue}',
      );
    }
    if (!manifest.canPerform(request.operation) ||
        request.operation == InboxOperation.ignore) {
      return ConnectorWriteResult.failed(
        summary: 'unsupported operation ${request.operation.storageValue}',
      );
    }
    if (failNextWrites > 0) {
      failNextWrites--;
      return const ConnectorWriteResult.failed(summary: 'injected failure');
    }

    // Idempotency: the same action retried must not create a second record.
    final existing = _byIdempotencyKey[request.idempotencyKey];
    if (existing != null) {
      if (omitExternalIds) {
        return const ConnectorWriteResult.succeeded(
          externalId: '',
          summary: 'idempotent replay without id',
        );
      }
      final updated = ConnectorRecord(
        externalId: existing,
        fieldsJson: request.fieldsJson,
      );
      _records[existing] = updated;
      return ConnectorWriteResult.succeeded(
        externalId: existing,
        summary: 'idempotent replay, updated in place',
      );
    }

    if (request.operation == InboxOperation.update ||
        request.operation == InboxOperation.append) {
      final target = request.targetExternalId;
      if (target == null || !_records.containsKey(target)) {
        return ConnectorWriteResult.failed(
          summary: 'update target not found: ${target ?? 'null'}',
        );
      }
      final updated = ConnectorRecord(
        externalId: target,
        fieldsJson: request.fieldsJson,
      );
      _records[target] = updated;
      _byIdempotencyKey[request.idempotencyKey] = target;
      return ConnectorWriteResult.succeeded(
        externalId: target,
        summary: 'updated',
      );
    }

    final externalId = '$_externalIdPrefix${++_sequence}';
    _records[externalId] = ConnectorRecord(
      externalId: externalId,
      fieldsJson: request.fieldsJson,
    );
    _byIdempotencyKey[request.idempotencyKey] = externalId;
    if (omitExternalIds) {
      return const ConnectorWriteResult.succeeded(
        externalId: '',
        summary: 'created but no id reported',
      );
    }
    return ConnectorWriteResult.succeeded(
      externalId: externalId,
      summary: 'created',
    );
  }

  @override
  Future<ConnectorRecord?> verify(String externalId) async =>
      _records[externalId];

  /// Clears all state, for a fresh test.
  void reset() {
    _records.clear();
    _byIdempotencyKey.clear();
    _sequence = 0;
    failNextWrites = 0;
    omitExternalIds = false;
  }
}
