import 'dart:async';

import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../models/inbox_enums.dart';
import 'connector.dart';

/// Registry of available connectors.
///
/// Lookup by id only; there is no "default destination" fallback, so disabling
/// or deleting a connector can never silently reroute a write somewhere else
/// (design test case 8).
class ConnectorRegistry {
  ConnectorRegistry([Iterable<ConnectorAccess> connectors = const []]) {
    for (final connector in connectors) {
      register(connector);
    }
  }

  final Map<String, ConnectorAccess> _connectors = {};

  void register(ConnectorAccess connector) {
    _connectors[connector.manifest.id] = connector;
  }

  void unregister(String connectorId) {
    _connectors.remove(connectorId);
  }

  ConnectorAccess? byId(String connectorId) => _connectors[connectorId];

  Iterable<ConnectorAccess> get all => _connectors.values;
}

/// A planned action as read back for review or execution.
class PlannedActionView {
  const PlannedActionView({
    required this.id,
    required this.planId,
    required this.entityType,
    required this.operation,
    required this.connectorId,
    required this.fieldsJson,
    required this.certainty,
    required this.risk,
    required this.approvalState,
    required this.idempotencyKey,
    this.targetExternalId,
    this.beforeJson,
    this.evidenceJson = '[]',
  });

  final String id;
  final String planId;
  final InboxEntityType entityType;
  final InboxOperation operation;
  final String connectorId;
  final String fieldsJson;
  final String? beforeJson;
  final String? targetExternalId;
  final String evidenceJson;
  final InboxCertainty certainty;
  final InboxRiskLevel risk;
  final InboxApprovalState approvalState;
  final String idempotencyKey;
}

/// The result of trying to execute one action.
class ExecutionReport {
  const ExecutionReport({
    required this.actionId,
    required this.outcome,
    required this.succeeded,
    required this.message,
    this.receiptId,
    this.externalId,
  });

  final String actionId;
  final InboxExecutionOutcome outcome;
  final bool succeeded;
  final String message;
  final String? receiptId;
  final String? externalId;
}

/// Writes approved actions to connectors and records what actually happened.
///
/// Invariants this class exists to hold:
///
/// - nothing is written without an approved [InboxApprovalState];
/// - the same action executed twice produces at most one remote object, because
///   the request carries a stable idempotency key and an existing confirmed
///   receipt short-circuits the second run;
/// - a status of `succeeded` is only ever reported when the connector returned a
///   confirmed result, so a failure or a timeout is never dressed up as success;
/// - a connector that cannot be found fails the action instead of falling back
///   to another destination.
class InboxExecutionEngine {
  InboxExecutionEngine({
    required this.db,
    required this.registry,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final AppDatabase db;
  final ConnectorRegistry registry;
  final DateTime Function() _now;

  /// The idempotency key for an operation, stable across retries and restarts.
  ///
  /// Derived from the content the action targets, not from a timestamp or a
  /// random id, so re-planning the same input yields the same key.
  static String idempotencyKeyFor({
    required String sourceContentHash,
    required InboxEntityType entityType,
    required InboxOperation operation,
    required String connectorId,
    String? targetExternalId,
  }) {
    final sign = [
      sourceContentHash,
      entityType.storageValue,
      operation.storageValue,
      connectorId,
      targetExternalId ?? '',
    ].join('\u0000');
    return _fnv1a(sign);
  }

  /// Records a plan and its actions, replacing any earlier plan for the item.
  ///
  /// Returns the new plan id. The plan starts as `pending_approval`: creating a
  /// plan never authorises a write.
  Future<String> savePlan({
    required String planId,
    required String itemId,
    required List<PlannedActionView> actions,
    required DateTime createdAt,
  }) async {
    await db.transaction(() async {
      await (db.delete(
        db.inboxActionPlans,
      )..where((row) => row.itemId.equals(itemId))).go();
      await db
          .into(db.inboxActionPlans)
          .insert(
            InboxActionPlansCompanion.insert(
              id: planId,
              itemId: itemId,
              version: 1,
              status: InboxPlanStatus.pendingApproval.storageValue,
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          );
      for (final action in actions) {
        await db
            .into(db.plannedActions)
            .insert(
              PlannedActionsCompanion.insert(
                id: action.id,
                planId: planId,
                entityType: action.entityType.storageValue,
                operation: action.operation.storageValue,
                connectorId: action.connectorId,
                targetExternalId: Value(action.targetExternalId),
                fieldsJson: action.fieldsJson,
                beforeJson: Value(action.beforeJson),
                evidenceJson: action.evidenceJson,
                certainty: action.certainty.storageValue,
                risk: action.risk.storageValue,
                approvalState: Value(action.approvalState.storageValue),
                idempotencyKey: action.idempotencyKey,
                createdAt: createdAt,
                updatedAt: createdAt,
              ),
            );
      }
    });
    return planId;
  }

  Future<List<PlannedActionView>> actionsForPlan(String planId) async {
    final rows = await (db.select(
      db.plannedActions,
    )..where((row) => row.planId.equals(planId))).get();
    return [
      for (final row in rows)
        PlannedActionView(
          id: row.id,
          planId: row.planId,
          entityType: InboxEntityType.tryParse(row.entityType)!,
          operation: InboxOperation.tryParse(row.operation)!,
          connectorId: row.connectorId,
          fieldsJson: row.fieldsJson,
          beforeJson: row.beforeJson,
          targetExternalId: row.targetExternalId,
          evidenceJson: row.evidenceJson,
          certainty: InboxCertainty.tryParse(row.certainty)!,
          risk: InboxRiskLevel.tryParse(row.risk)!,
          approvalState: InboxApprovalState.tryParse(row.approvalState)!,
          idempotencyKey: row.idempotencyKey,
        ),
    ];
  }

  /// Sets an action's approval. Rejection is final for this plan revision.
  Future<void> setApproval(
    String actionId,
    InboxApprovalState state, {
    required DateTime at,
  }) async {
    await (db.update(
      db.plannedActions,
    )..where((r) => r.id.equals(actionId))).write(
      PlannedActionsCompanion(
        approvalState: Value(state.storageValue),
        updatedAt: Value(at),
      ),
    );
  }

  /// Executes one approved action.
  ///
  /// A previously confirmed receipt for this action short-circuits execution, so
  /// retrying after a partial failure cannot write the object twice.
  Future<ExecutionReport> execute(String actionId) async {
    final row = await (db.select(
      db.plannedActions,
    )..where((r) => r.id.equals(actionId))).getSingleOrNull();
    if (row == null) {
      throw StateError('planned_action_missing:$actionId');
    }
    final approval = InboxApprovalState.tryParse(row.approvalState);
    final risk = InboxRiskLevel.tryParse(row.risk);
    final operation = InboxOperation.tryParse(row.operation);
    final entityType = InboxEntityType.tryParse(row.entityType);
    if (approval == null ||
        risk == null ||
        operation == null ||
        entityType == null) {
      throw StateError('planned_action_corrupt:$actionId');
    }

    if (approval != InboxApprovalState.approved) {
      return ExecutionReport(
        actionId: actionId,
        outcome: InboxExecutionOutcome.rejected,
        succeeded: false,
        message: 'action is ${approval.storageValue}, not approved',
      );
    }

    // Nothing to write: an `ignore` proposal is recorded, not executed.
    if (!operation.writes) {
      return ExecutionReport(
        actionId: actionId,
        outcome: InboxExecutionOutcome.succeeded,
        succeeded: true,
        message: 'ignored, nothing written',
      );
    }

    // Already confirmed: never write twice, even on an explicit retry.
    final confirmed =
        await (db.select(db.executionReceipts)
              ..where(
                (r) =>
                    r.actionId.equals(actionId) &
                    r.outcome.equals(
                      InboxExecutionOutcome.succeeded.storageValue,
                    ),
              )
              ..limit(1))
            .getSingleOrNull();
    if (confirmed != null) {
      return ExecutionReport(
        actionId: actionId,
        outcome: InboxExecutionOutcome.succeeded,
        succeeded: true,
        message: 'already executed',
        receiptId: confirmed.id,
        externalId: confirmed.externalId,
      );
    }

    final connector = registry.byId(row.connectorId);
    if (connector == null) {
      return _recordFailure(
        actionId: actionId,
        connectorId: row.connectorId,
        outcome: InboxExecutionOutcome.failed,
        message: 'connector unavailable: ${row.connectorId}',
        fingerprint: row.idempotencyKey,
      );
    }

    if (!connector.manifest.supports(entityType)) {
      return _recordFailure(
        actionId: actionId,
        connectorId: row.connectorId,
        outcome: InboxExecutionOutcome.failed,
        message: 'connector cannot write ${entityType.storageValue}',
        fingerprint: row.idempotencyKey,
      );
    }
    if (!connector.manifest.canPerform(operation)) {
      return _recordFailure(
        actionId: actionId,
        connectorId: row.connectorId,
        outcome: InboxExecutionOutcome.failed,
        message: 'connector cannot ${operation.storageValue}',
        fingerprint: row.idempotencyKey,
      );
    }

    final ConnectorWriteResult result;
    try {
      result = await connector.execute(
        ConnectorWriteRequest(
          actionId: actionId,
          entityType: entityType,
          operation: operation,
          fieldsJson: row.fieldsJson,
          idempotencyKey: row.idempotencyKey,
          targetExternalId: row.targetExternalId,
        ),
      );
    } on TimeoutException catch (_) {
      return _recordFailure(
        actionId: actionId,
        connectorId: row.connectorId,
        outcome: InboxExecutionOutcome.timedOut,
        message: 'connector timed out',
        fingerprint: row.idempotencyKey,
      );
    } catch (error) {
      return _recordFailure(
        actionId: actionId,
        connectorId: row.connectorId,
        outcome: InboxExecutionOutcome.failed,
        message: 'connector threw: $error',
        fingerprint: row.idempotencyKey,
      );
    }

    // A connector that reports success without an id has not confirmed
    // anything; record it as a failure instead of claiming the write happened.
    if (!result.isConfirmed) {
      return _recordFailure(
        actionId: actionId,
        connectorId: row.connectorId,
        outcome: result.outcome == InboxExecutionOutcome.succeeded
            ? InboxExecutionOutcome.failed
            : result.outcome,
        message: result.outcome == InboxExecutionOutcome.succeeded
            ? 'connector returned no external id'
            : (result.summary.isEmpty ? 'connector failed' : result.summary),
        fingerprint: row.idempotencyKey,
      );
    }

    final receiptId = _receiptId(actionId);
    await db
        .into(db.executionReceipts)
        .insert(
          ExecutionReceiptsCompanion.insert(
            id: receiptId,
            actionId: actionId,
            connectorId: row.connectorId,
            externalId: Value(result.externalId),
            outcome: InboxExecutionOutcome.succeeded.storageValue,
            requestFingerprint: row.idempotencyKey,
            responseSummary: result.summary,
            executedAt: _now(),
          ),
        );
    await _appendAudit(
      itemId: null,
      actionId: actionId,
      eventType: 'action_executed',
      detailsJson: '{"externalId":"${result.externalId}"}',
    );

    return ExecutionReport(
      actionId: actionId,
      outcome: InboxExecutionOutcome.succeeded,
      succeeded: true,
      message: result.summary.isEmpty ? 'written' : result.summary,
      receiptId: receiptId,
      externalId: result.externalId,
    );
  }

  /// Executes every approved action in a plan.
  ///
  /// Returns per-action reports; a partial success is expressed by a mix of
  /// outcomes rather than being collapsed into one global "done".
  Future<List<ExecutionReport>> executePlan(String planId) async {
    final actions = await actionsForPlan(planId);
    final reports = <ExecutionReport>[];
    for (final action in actions) {
      if (action.approvalState != InboxApprovalState.approved) {
        continue;
      }
      reports.add(await execute(action.id));
    }
    return reports;
  }

  Future<List<ExecutionReceipt>> receiptsForAction(String actionId) {
    return (db.select(
      db.executionReceipts,
    )..where((r) => r.actionId.equals(actionId))).get();
  }

  Future<ExecutionReport> _recordFailure({
    required String actionId,
    required String connectorId,
    required InboxExecutionOutcome outcome,
    required String message,
    required String fingerprint,
  }) async {
    final receiptId = _receiptId(actionId);
    await db
        .into(db.executionReceipts)
        .insert(
          ExecutionReceiptsCompanion.insert(
            id: receiptId,
            actionId: actionId,
            connectorId: connectorId,
            externalId: const Value(null),
            outcome: outcome.storageValue,
            requestFingerprint: fingerprint,
            responseSummary: message,
            executedAt: _now(),
          ),
        );
    await _appendAudit(
      itemId: null,
      actionId: actionId,
      eventType: 'action_failed',
      detailsJson: '{"outcome":"${outcome.storageValue}"}',
    );
    return ExecutionReport(
      actionId: actionId,
      outcome: outcome,
      succeeded: false,
      message: message,
      receiptId: receiptId,
    );
  }

  Future<void> _appendAudit({
    required String? itemId,
    required String? actionId,
    required String eventType,
    required String detailsJson,
  }) async {
    final at = _now();
    await db
        .into(db.inboxAuditEvents)
        .insert(
          InboxAuditEventsCompanion.insert(
            id: 'audit-${at.microsecondsSinceEpoch}-$eventType',
            itemId: Value(itemId),
            actionId: Value(actionId),
            eventType: eventType,
            timestamp: at,
            detailsJson: detailsJson,
          ),
        );
  }

  String _receiptId(String actionId) =>
      'receipt-$actionId-${_now().microsecondsSinceEpoch}';
}

String _fnv1a(String input) {
  var hash = 0xcbf29ce484222325;
  for (final byte in input.codeUnits) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}
