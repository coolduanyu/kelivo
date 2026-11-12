import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/inbox_store.dart';
import 'package:Kelivo/core/models/inbox_enums.dart';
import 'package:Kelivo/core/models/inbox_item.dart';

void main() {
  late AppDatabase db;
  late InboxStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = InboxStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  InboxCapture item({
    String id = 'item-1',
    InboxSourceType sourceType = InboxSourceType.share,
    String? text = '本周五前准备融资方案',
    String? hash,
    List<InboxCaptureAttachment> attachments = const [],
  }) {
    return InboxCapture(
      id: id,
      sourceType: sourceType,
      rawText: text,
      contentHash: hash ?? inboxContentHash(text: text),
      capturedAt: DateTime.utc(2026, 11, 12, 8, 0),
      timezone: 'Asia/Dubai',
      sourceApp: 'WeChat',
      attachments: attachments,
    );
  }

  group('capture', () {
    test('stores an item and reads it back with its attachments', () async {
      final outcome = await store.capture(
        item(
          attachments: const [
            InboxCaptureAttachment(
              id: 'att-1',
              localPath: '/data/inbox/att-1.png',
              mime: 'image/png',
              sizeBytes: 1024,
              sha256: 'abc',
            ),
          ],
        ),
      );

      expect(outcome, isA<InboxCaptured>());
      final loaded = await store.findItem('item-1');
      expect(loaded, isNotNull);
      expect(loaded!.status, InboxItemStatus.received);
      expect(loaded.timezone, 'Asia/Dubai');
      expect(loaded.attachments, hasLength(1));
      expect(
        loaded.attachments.single.retentionPolicy,
        InboxRetentionPolicy.keep,
      );
    });

    test(
      're-importing identical content is a duplicate, not a new row',
      () async {
        await store.capture(item());
        final second = await store.capture(item(id: 'item-2'));

        expect(second, isA<InboxCaptureDuplicate>());
        expect((second as InboxCaptureDuplicate).existingItemId, 'item-1');
        expect(await store.listItems(), hasLength(1));
      },
    );

    test(
      'the same content from a different surface is not a duplicate',
      () async {
        await store.capture(item(sourceType: InboxSourceType.share));
        final second = await store.capture(
          item(id: 'item-2', sourceType: InboxSourceType.clipboard),
        );

        expect(second, isA<InboxCaptured>());
        expect(await store.listItems(), hasLength(2));
      },
    );

    test('content hash is order-independent for multiple attachments', () {
      final a = inboxContentHash(
        text: 'x',
        attachmentSha256: const ['aaa', 'bbb'],
      );
      final b = inboxContentHash(
        text: 'x',
        attachmentSha256: const ['bbb', 'aaa'],
      );
      expect(a, b);
      expect(
        a,
        isNot(
          inboxContentHash(text: 'y', attachmentSha256: const ['aaa', 'bbb']),
        ),
      );
    });
  });

  group('state machine', () {
    test('follows the approved happy path through to success', () async {
      await store.capture(item());
      final at = DateTime.utc(2026, 11, 12, 9);

      for (final next in [
        InboxItemStatus.preparing,
        InboxItemStatus.extracting,
        InboxItemStatus.reconciling,
        InboxItemStatus.proposed,
        InboxItemStatus.approved,
        InboxItemStatus.executing,
        InboxItemStatus.succeeded,
      ]) {
        await store.transition('item-1', next, at: at);
      }

      expect(
        (await store.findItem('item-1'))!.status,
        InboxItemStatus.succeeded,
      );
    });

    test('rejects skipping straight from received to succeeded', () async {
      await store.capture(item());

      await expectLater(
        store.transition(
          'item-1',
          InboxItemStatus.succeeded,
          at: DateTime.utc(2026, 11, 12, 9),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('inbox_item_illegal_transition'),
          ),
        ),
      );
      expect(
        (await store.findItem('item-1'))!.status,
        InboxItemStatus.received,
      );
    });

    test('a rejected item cannot later be executed', () async {
      await store.capture(item());
      final at = DateTime.utc(2026, 11, 12, 9);
      for (final next in [
        InboxItemStatus.preparing,
        InboxItemStatus.extracting,
        InboxItemStatus.reconciling,
        InboxItemStatus.proposed,
        InboxItemStatus.rejected,
      ]) {
        await store.transition('item-1', next, at: at);
      }

      await expectLater(
        store.transition('item-1', InboxItemStatus.executing, at: at),
        throwsA(isA<StateError>()),
      );
    });

    test('a failure can be recorded mid-flight and is terminal', () async {
      await store.capture(item());
      final at = DateTime.utc(2026, 11, 12, 9);
      await store.transition('item-1', InboxItemStatus.preparing, at: at);
      await store.transition('item-1', InboxItemStatus.failed, at: at);

      expect((await store.findItem('item-1'))!.status, InboxItemStatus.failed);
      expect(InboxItemStatus.failed.isTerminal, isTrue);
      await expectLater(
        store.transition('item-1', InboxItemStatus.extracting, at: at),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('extracted events', () {
    test('replaces the previous set and preserves certainty', () async {
      await store.capture(item());
      await store.replaceExtractedEvents('item-1', [
        const InboxExtractedEvent(
          id: 'ev-1',
          itemId: 'item-1',
          entityType: InboxEntityType.task,
          certainty: InboxCertainty.fact,
          payloadJson: '{"title":"准备融资方案"}',
          evidenceJson: '[{"quote":"本周五前准备融资方案"}]',
          extractionVersion: 'v1',
        ),
      ]);

      var events = await store.listExtractedEvents('item-1');
      expect(events, hasLength(1));
      expect(events.single.entityType, InboxEntityType.task);
      expect(events.single.certainty, InboxCertainty.fact);

      await store.replaceExtractedEvents('item-1', [
        const InboxExtractedEvent(
          id: 'ev-2',
          itemId: 'item-1',
          entityType: InboxEntityType.meeting,
          certainty: InboxCertainty.unverified,
          payloadJson: '{"title":"下周二下午"}',
          evidenceJson: '[]',
          extractionVersion: 'v1',
        ),
      ]);

      events = await store.listExtractedEvents('item-1');
      expect(events, hasLength(1));
      expect(events.single.id, 'ev-2');
      expect(events.single.certainty, InboxCertainty.unverified);
    });

    test('rejects an event whose item id does not match', () async {
      await store.capture(item());
      await expectLater(
        store.replaceExtractedEvents('item-1', [
          const InboxExtractedEvent(
            id: 'ev-x',
            itemId: 'other-item',
            entityType: InboxEntityType.note,
            certainty: InboxCertainty.fact,
            payloadJson: '{}',
            evidenceJson: '[]',
            extractionVersion: 'v1',
          ),
        ]),
        throwsA(isA<StateError>()),
      );
      expect(await store.listExtractedEvents('item-1'), isEmpty);
    });
  });
}
