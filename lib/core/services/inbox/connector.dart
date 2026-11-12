import 'dart:async';

import '../../models/inbox_enums.dart';

/// What a connector can actually do, as it declares it.
///
/// This is deliberately conservative: a connector that cannot search or read
/// back must say so, because the design forbids silently duplicating remote
/// records. [canSearch]/[canGet] drive the duplicate-creation warning.
class ConnectorManifest {
  const ConnectorManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.supportedEntities,
    required this.operations,
    this.canSearch = false,
    this.canGet = false,
    this.requiresApproval = true,
  });

  final String id;
  final String name;
  final String version;
  final Set<InboxEntityType> supportedEntities;
  final Set<InboxOperation> operations;

  /// Whether [ConnectorAccess.search] is meaningful.
  final bool canSearch;

  /// Whether [ConnectorAccess.get] is meaningful.
  final bool canGet;

  /// Whether every write through this connector needs human approval. High-risk
  /// actions always do, independent of this flag.
  final bool requiresApproval;

  bool supports(InboxEntityType entityType) =>
      supportedEntities.contains(entityType);

  bool canPerform(InboxOperation operation) => operations.contains(operation);

  /// The design's warning: without read-back capability the system cannot tell
  /// whether a record already exists, so automation must be downgraded.
  bool get canDetectDuplicates => canSearch && canGet;
}

/// A connector's answer to a read query.
class ConnectorRecord {
  const ConnectorRecord({required this.externalId, required this.fieldsJson});

  final String externalId;

  /// The remote object's fields, as JSON, for diffing against a proposal.
  final String fieldsJson;
}

/// The result of attempting a write.
///
/// A connector must report the remote identifier it created or updated. If it
/// cannot, the write is treated as unconfirmed rather than assumed successful.
class ConnectorWriteResult {
  const ConnectorWriteResult({
    required this.outcome,
    this.externalId,
    this.summary = '',
  });

  const ConnectorWriteResult.succeeded({
    required String externalId,
    String summary = '',
  }) : this(
         outcome: InboxExecutionOutcome.succeeded,
         externalId: externalId,
         summary: summary,
       );

  const ConnectorWriteResult.failed({String summary = ''})
    : this(outcome: InboxExecutionOutcome.failed, summary: summary);

  const ConnectorWriteResult.timedOut({String summary = ''})
    : this(outcome: InboxExecutionOutcome.timedOut, summary: summary);

  final InboxExecutionOutcome outcome;
  final String? externalId;
  final String summary;

  /// A write counts as confirmed only with both a success outcome and an
  /// identifier the caller can point at later.
  bool get isConfirmed =>
      outcome.isWriteConfirmed && externalId != null && externalId!.isNotEmpty;
}

/// A validated action handed to a connector for execution.
///
/// Fields are already schema-checked by the planner; a connector never receives
/// raw model output.
class ConnectorWriteRequest {
  const ConnectorWriteRequest({
    required this.actionId,
    required this.entityType,
    required this.operation,
    required this.fieldsJson,
    required this.idempotencyKey,
    this.targetExternalId,
  });

  final String actionId;
  final InboxEntityType entityType;
  final InboxOperation operation;
  final String fieldsJson;

  /// Stable across retries, so a connector can deduplicate.
  final String idempotencyKey;

  /// Set for update/append; null for create.
  final String? targetExternalId;
}

/// A connector's transport-level interface.
///
/// Implementations must not invent success: an unsupported operation or an
/// unreachable service must produce a failure result, never a fabricated id.
abstract class ConnectorAccess {
  ConnectorManifest get manifest;

  Future<void> connect();
  Future<void> disconnect();

  Future<List<ConnectorRecord>> search(
    InboxEntityType entityType,
    String query, {
    int limit = 20,
  });

  Future<ConnectorRecord?> get(InboxEntityType entityType, String externalId);

  Future<ConnectorWriteResult> execute(ConnectorWriteRequest request);

  /// Re-reads what was written so the caller can confirm the remote state.
  Future<ConnectorRecord?> verify(String externalId);
}

/// A transport-level failure from the calendar API.
class ConnectorHttpException implements Exception {
  const ConnectorHttpException({
    required this.statusCode,
    required this.message,
  });

  final int statusCode;
  final String message;

  @override
  String toString() => 'ConnectorHttpException($statusCode, $message)';
}
