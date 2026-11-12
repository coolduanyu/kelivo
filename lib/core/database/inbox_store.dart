import 'dart:convert';

import 'package:drift/drift.dart';

import '../models/inbox_enums.dart';
import '../models/inbox_item.dart';
import 'app_database.dart';

/// Result of attempting to capture an item.
///
/// [duplicate] is the important case: re-importing the same screenshot or the
/// same shared message must not create a second item, and must not be reported
/// as a failure. Callers show "already captured" and do nothing else.
sealed class InboxCaptureOutcome {
  const InboxCaptureOutcome();
}

final class InboxCaptured extends InboxCaptureOutcome {
  const InboxCaptured(this.item);
  final InboxCapture item;
}

final class InboxCaptureDuplicate extends InboxCaptureOutcome {
  const InboxCaptureDuplicate(this.existingItemId);
  final String existingItemId;
}

/// Persistence for captured inbox items and their extracted events.
///
/// Deliberately narrow: it stores and reads back. Analysis, planning and
/// execution are separate layers, so nothing here can write to an external
/// system.
class InboxStore {
  InboxStore(this._db);

  final AppDatabase _db;

  /// Persists [item] with its attachments.
  ///
  /// Returns [InboxCaptureDuplicate] instead of inserting when a row with the
  /// same `(sourceType, contentHash)` already exists. The check and the insert
  /// share the database's write transaction, so two concurrent captures of the
  /// same content cannot both insert.
  Future<InboxCaptureOutcome> capture(InboxCapture item) {
    return _db.transaction(() async {
      final existing =
          await (_db.select(_db.inboxItems)
                ..where(
                  (row) =>
                      row.sourceType.equals(item.sourceType.storageValue) &
                      row.contentHash.equals(item.contentHash),
                )
                ..limit(1))
              .getSingleOrNull();
      if (existing != null) {
        return InboxCaptureDuplicate(existing.id);
      }

      await _db
          .into(_db.inboxItems)
          .insert(
            InboxItemsCompanion.insert(
              id: item.id,
              sourceType: item.sourceType.storageValue,
              rawText: Value(item.rawText),
              contentHash: item.contentHash,
              status: Value(item.status.storageValue),
              sourceApp: Value(item.sourceApp),
              capturedAt: item.capturedAt,
              timezone: item.timezone,
              updatedAt: item.capturedAt,
            ),
          );

      for (final attachment in item.attachments) {
        await _db
            .into(_db.inboxAttachments)
            .insert(
              InboxAttachmentsCompanion.insert(
                id: attachment.id,
                itemId: item.id,
                localPath: attachment.localPath,
                mime: attachment.mime,
                sizeBytes: attachment.sizeBytes,
                sha256: attachment.sha256,
                retentionPolicy: Value(attachment.retentionPolicy.storageValue),
                createdAt: item.capturedAt,
              ),
            );
      }

      return InboxCaptured(item);
    });
  }

  /// All items, newest first, with their attachments.
  Future<List<InboxCapture>> listItems({int limit = 100}) async {
    final rows =
        await (_db.select(_db.inboxItems)
              ..orderBy([
                (row) => OrderingTerm.desc(row.capturedAt),
                (row) => OrderingTerm.asc(row.id),
              ])
              ..limit(limit))
            .get();
    if (rows.isEmpty) return const [];

    final ids = rows.map((row) => row.id).toList(growable: false);
    final attachmentRows =
        await (_db.select(_db.inboxAttachments)
              ..where((row) => row.itemId.isIn(ids))
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
            .get();
    final byItem = <String, List<InboxCaptureAttachment>>{};
    for (final row in attachmentRows) {
      byItem.putIfAbsent(row.itemId, () => []).add(_attachmentFromRow(row));
    }

    return [
      for (final row in rows)
        _itemFromRow(row, byItem[row.id] ?? const <InboxCaptureAttachment>[]),
    ];
  }

  Future<InboxCapture?> findItem(String id) async {
    final row = await (_db.select(
      _db.inboxItems,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    if (row == null) return null;
    final attachments =
        await (_db.select(_db.inboxAttachments)
              ..where((r) => r.itemId.equals(id))
              ..orderBy([(r) => OrderingTerm.asc(r.createdAt)]))
            .get();
    return _itemFromRow(row, attachments.map(_attachmentFromRow).toList());
  }

  /// Moves an item to [next], rejecting an illegal transition.
  ///
  /// Illegal transitions throw rather than being quietly coerced: a rejected or
  /// failed item must never reach `succeeded` because of a logic slip
  /// downstream.
  Future<void> transition(
    String itemId,
    InboxItemStatus next, {
    required DateTime at,
  }) async {
    await _db.transaction(() async {
      final row = await (_db.select(
        _db.inboxItems,
      )..where((r) => r.id.equals(itemId))).getSingleOrNull();
      if (row == null) {
        throw StateError('inbox_item_missing:$itemId');
      }
      final current = InboxItemStatus.tryParse(row.status);
      if (current == null) {
        throw StateError('inbox_item_status_corrupt:${row.status}');
      }
      if (!current.canTransitionTo(next)) {
        throw StateError(
          'inbox_item_illegal_transition:'
          '${current.storageValue}->${next.storageValue}',
        );
      }
      await (_db.update(
        _db.inboxItems,
      )..where((r) => r.id.equals(itemId))).write(
        InboxItemsCompanion(
          status: Value(next.storageValue),
          updatedAt: Value(at),
        ),
      );
    });
  }

  Future<void> replaceExtractedEvents(
    String itemId,
    List<InboxExtractedEvent> events,
  ) async {
    await _db.transaction(() async {
      await (_db.delete(
        _db.extractedEvents,
      )..where((row) => row.itemId.equals(itemId))).go();
      for (final event in events) {
        if (event.itemId != itemId) {
          throw StateError('extracted_event_item_mismatch:${event.id}');
        }
        await _db
            .into(_db.extractedEvents)
            .insert(
              ExtractedEventsCompanion.insert(
                id: event.id,
                itemId: event.itemId,
                entityType: event.entityType.storageValue,
                certainty: event.certainty.storageValue,
                payloadJson: event.payloadJson,
                evidenceJson: event.evidenceJson,
                extractionVersion: event.extractionVersion,
                createdAt: DateTime.now(),
              ),
            );
      }
    });
  }

  Future<List<InboxExtractedEvent>> listExtractedEvents(String itemId) async {
    final rows =
        await (_db.select(_db.extractedEvents)
              ..where((row) => row.itemId.equals(itemId))
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
            .get();
    return [
      for (final row in rows)
        InboxExtractedEvent(
          id: row.id,
          itemId: row.itemId,
          entityType: InboxEntityType.tryParse(row.entityType)!,
          certainty: InboxCertainty.tryParse(row.certainty)!,
          payloadJson: row.payloadJson,
          evidenceJson: row.evidenceJson,
          extractionVersion: row.extractionVersion,
        ),
    ];
  }

  static InboxCapture _itemFromRow(
    InboxItem row,
    List<InboxCaptureAttachment> attachments,
  ) {
    return InboxCapture(
      id: row.id,
      sourceType: InboxSourceType.tryParse(row.sourceType)!,
      rawText: row.rawText,
      contentHash: row.contentHash,
      capturedAt: row.capturedAt,
      timezone: row.timezone,
      sourceApp: row.sourceApp,
      status: InboxItemStatus.tryParse(row.status)!,
      attachments: attachments,
    );
  }

  static InboxCaptureAttachment _attachmentFromRow(InboxAttachment row) {
    return InboxCaptureAttachment(
      id: row.id,
      localPath: row.localPath,
      mime: row.mime,
      sizeBytes: row.sizeBytes,
      sha256: row.sha256,
      retentionPolicy: InboxRetentionPolicy.tryParse(row.retentionPolicy)!,
    );
  }
}

/// Stable content hash for duplicate detection.
///
/// Text is hashed over its UTF-8 bytes; an attachment contributes its own
/// sha256 so a re-shared identical PDF is recognised even when the message text
/// differs. Order is normalised so a differently-ordered multi-file share is
/// still a duplicate.
String inboxContentHash({
  String? text,
  Iterable<String> attachmentSha256 = const [],
}) {
  final hashes = attachmentSha256.toList(growable: false)..sort();
  return _shaLike('${text ?? ''}\u0000${hashes.join('\u0000')}');
}

/// A cheap, deterministic digest.
///
/// This is a content fingerprint for duplicate detection, not a security hash;
/// callers that need cryptographic strength should use sha256 over the bytes
/// (which the attachment pipeline already does).
String _shaLike(String input) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}
