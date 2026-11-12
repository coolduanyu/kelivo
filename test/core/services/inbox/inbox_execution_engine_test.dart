import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/models/inbox_enums.dart';
import 'package:Kelivo/core/services/inbox/connector.dart';
import 'package:Kelivo/core/services/inbox/demo_connector.dart';
import 'package:Kelivo/core/services/inbox/inbox_execution_engine.dart';

void main() {
  late AppDatabase db;
  late DemoConnector connector;
  late ConnectorRegistry registry;
  late InboxExecutionEngine engine;
  var now = DateTime.utc(2026, 11, 12, 10);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    connector = DemoConnector();
    await connector.connect();
    registry = ConnectorRegistry([connector]);
    engine = InboxExecutionEngine(db: db, registry: registry, clock: () => now);
    now = DateTime.utc(2026, 11, 12, 10);

    // A plan needs a real item row because plans cascade from it.
    await db
        .into(db.inboxItems)
        .insert(
          InboxItemsCompanion.insert(
            id: 'item-1',
            sourceType: InboxSourceType.share.storageValue,
            rawText: const Value('本周五前准备融资方案'),
            contentHash: 'hash-1',
            capturedAt: now,
            timezone: 'Asia/Dubai',
            updatedAt: now,
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  String keyFor({
    InboxOperation operation = InboxOperation.create,
    String? target,
  }) {
    return InboxExecutionEngine.idempotencyKeyFor(
      sourceContentHash: 'hash-1',
      entityType: InboxEntityType.task,
      operation: operation,
      connectorId: 'demo',
      targetExternalId: target,
    );
  }

  PlannedActionView action({
    String id = 'action-1',
    InboxOperation operation = InboxOperation.create,
    InboxRiskLevel risk = InboxRiskLevel.normal,
    InboxApprovalState approval = InboxApprovalState.pending,
    String? targetExternalId,
    String contentHash = 'hash-1',
  }) {
    return PlannedActionView(
      id: id,
      planId: 'plan-1',
      entityType: InboxEntityType.task,
      operation: operation,
      connectorId: 'demo',
      fieldsJson: '{"title":"准备融资方案"}',
      certainty: InboxCertainty.fact,
      risk: risk,
      approvalState: approval,
      idempotencyKey: InboxExecutionEngine.idempotencyKeyFor(
        sourceContentHash: contentHash,
        entityType: InboxEntityType.task,
        operation: operation,
        connectorId: 'demo',
        targetExternalId: targetExternalId,
      ),
      targetExternalId: targetExternalId,
    );
  }

  test('an unapproved action is never written', () async {
    await engine.savePlan(
      planId: 'plan-1',
      itemId: 'item-1',
      actions: [action()],
      createdAt: now,
    );

    final report = await engine.execute('action-1');
    expect(report.succeeded, isFalse);
    expect(report.outcome, InboxExecutionOutcome.rejected);
    expect(connector.records, isEmpty);
  });

  test('an approved action writes once and records a receipt', () async {
    await engine.savePlan(
      planId: 'plan-1',
      itemId: 'item-1',
      actions: [action(approval: InboxApprovalState.approved)],
      createdAt: now,
    );

    final report = await engine.execute('action-1');
    expect(report.succeeded, isTrue);
    expect(report.outcome, InboxExecutionOutcome.succeeded);
    expect(report.externalId, isNotNull);
    expect(connector.records, hasLength(1));

    final receipts = await engine.receiptsForAction('action-1');
    expect(receipts, hasLength(1));
    expect(
      receipts.single.outcome,
      InboxExecutionOutcome.succeeded.storageValue,
    );
    expect(receipts.single.externalId, report.externalId);
  });

  test(
    're-executing the same action does not create a second record',
    () async {
      await engine.savePlan(
        planId: 'plan-1',
        itemId: 'item-1',
        actions: [action(approval: InboxApprovalState.approved)],
        createdAt: now,
      );

      final first = await engine.execute('action-1');
      final second = await engine.execute('action-1');

      expect(first.externalId, second.externalId);
      expect(second.message, 'already executed');
      expect(connector.records, hasLength(1));
    },
  );

  test('the idempotency key is stable across replanning', () {
    final a = InboxExecutionEngine.idempotencyKeyFor(
      sourceContentHash: 'hash-1',
      entityType: InboxEntityType.task,
      operation: InboxOperation.create,
      connectorId: 'demo',
    );
    final b = InboxExecutionEngine.idempotencyKeyFor(
      sourceContentHash: 'hash-1',
      entityType: InboxEntityType.task,
      operation: InboxOperation.create,
      connectorId: 'demo',
    );
    expect(a, b);

    // A different target is a different write.
    expect(
      keyFor(operation: InboxOperation.update, target: 'demo-1'),
      isNot(keyFor(operation: InboxOperation.update, target: 'demo-2')),
    );
  });

  test('a connector failure is reported as failure with a receipt', () async {
    connector.failNextWrites = 1;
    await engine.savePlan(
      planId: 'plan-1',
      itemId: 'item-1',
      actions: [action(approval: InboxApprovalState.approved)],
      createdAt: now,
    );

    final report = await engine.execute('action-1');
    expect(report.succeeded, isFalse);
    expect(report.outcome, InboxExecutionOutcome.failed);
    expect(connector.records, isEmpty);

    final receipts = await engine.receiptsForAction('action-1');
    expect(receipts.single.outcome, InboxExecutionOutcome.failed.storageValue);
  });

  test('a success without an external id is not treated as written', () async {
    connector.omitExternalIds = true;
    await engine.savePlan(
      planId: 'plan-1',
      itemId: 'item-1',
      actions: [action(approval: InboxApprovalState.approved)],
      createdAt: now,
    );

    final report = await engine.execute('action-1');
    expect(report.succeeded, isFalse);
    expect(report.message, contains('no external id'));
  });

  test('an unreachable connector fails instead of rerouting', () async {
    registry.unregister('demo');
    await engine.savePlan(
      planId: 'plan-1',
      itemId: 'item-1',
      actions: [action(approval: InboxApprovalState.approved)],
      createdAt: now,
    );

    final report = await engine.execute('action-1');
    expect(report.succeeded, isFalse);
    expect(report.message, contains('connector unavailable'));
    expect(connector.records, isEmpty);
  });

  test('an ignore proposal is recorded but writes nothing', () async {
    await engine.savePlan(
      planId: 'plan-1',
      itemId: 'item-1',
      actions: [
        action(
          operation: InboxOperation.ignore,
          approval: InboxApprovalState.approved,
        ),
      ],
      createdAt: now,
    );

    final report = await engine.execute('action-1');
    expect(report.succeeded, isTrue);
    expect(connector.records, isEmpty);
  });

  test(
    'executePlan only runs approved actions and reports partial results',
    () async {
      await engine.savePlan(
        planId: 'plan-1',
        itemId: 'item-1',
        actions: [
          action(id: 'a-ok', approval: InboxApprovalState.approved),
          action(id: 'a-skip', approval: InboxApprovalState.rejected),
          action(
            id: 'a-write2',
            approval: InboxApprovalState.approved,
            contentHash: 'hash-2',
          ),
        ],
        createdAt: now,
      );
      connector.failNextWrites = 1;

      final reports = await engine.executePlan('plan-1');
      expect(reports, hasLength(2));
      expect(reports.where((r) => r.succeeded), hasLength(1));
      expect(reports.where((r) => !r.succeeded), hasLength(1));
    },
  );

  test(
    'demo connector dedupes by idempotency key on direct execution',
    () async {
      final request = ConnectorWriteRequest(
        actionId: 'x',
        entityType: InboxEntityType.task,
        operation: InboxOperation.create,
        fieldsJson: '{"title":"t"}',
        idempotencyKey: 'stable-key',
      );
      final first = await connector.execute(request);
      final second = await connector.execute(request);

      expect(first.externalId, second.externalId);
      expect(connector.records, hasLength(1));
    },
  );

  test('demo connector refuses unsupported operations', () async {
    final limited = DemoConnector(entities: {});
    await limited.connect();
    final result = await limited.execute(
      ConnectorWriteRequest(
        actionId: 'x',
        entityType: InboxEntityType.task,
        operation: InboxOperation.create,
        fieldsJson: '{}',
        idempotencyKey: 'k',
      ),
    );
    expect(result.isConfirmed, isFalse);
  });
}
