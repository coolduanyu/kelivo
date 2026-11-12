import 'inbox_enums.dart';

/// A captured piece of unstructured input, before any analysis.
///
/// This mirrors the `inbox_items` row but stays a plain value object so the
/// capture surfaces can build one without a database handle. Persistence is a
/// separate concern ([InboxStore]).
class InboxCapture {
  const InboxCapture({
    required this.id,
    required this.sourceType,
    required this.contentHash,
    required this.capturedAt,
    required this.timezone,
    this.rawText,
    this.sourceApp,
    this.status = InboxItemStatus.received,
    this.attachments = const [],
  });

  final String id;
  final InboxSourceType sourceType;

  /// Text the user shared or pasted. Null for an image-only capture.
  final String? rawText;

  /// Stable hash of the canonical input content. Used to make re-import
  /// idempotent: identical content from the same [sourceType] is a duplicate.
  final String contentHash;

  final DateTime capturedAt;

  /// IANA zone the input was received in, e.g. `Asia/Dubai`. Relative dates in
  /// the text are resolved against this, never the device's current zone.
  final String timezone;

  final String? sourceApp;
  final InboxItemStatus status;
  final List<InboxCaptureAttachment> attachments;

  bool get hasAttachments => attachments.isNotEmpty;

  InboxCapture copyWith({
    String? id,
    InboxSourceType? sourceType,
    String? rawText,
    String? contentHash,
    DateTime? capturedAt,
    String? timezone,
    String? sourceApp,
    InboxItemStatus? status,
    List<InboxCaptureAttachment>? attachments,
  }) {
    return InboxCapture(
      id: id ?? this.id,
      sourceType: sourceType ?? this.sourceType,
      rawText: rawText ?? this.rawText,
      contentHash: contentHash ?? this.contentHash,
      capturedAt: capturedAt ?? this.capturedAt,
      timezone: timezone ?? this.timezone,
      sourceApp: sourceApp ?? this.sourceApp,
      status: status ?? this.status,
      attachments: attachments ?? this.attachments,
    );
  }
}

/// A file or image that arrived with an [InboxItem].
///
/// [localPath] always points at app-controlled storage. The original
/// `content://` or OS temp path is deliberately not retained: both can become
/// unreadable once the source app closes.
class InboxCaptureAttachment {
  const InboxCaptureAttachment({
    required this.id,
    required this.localPath,
    required this.mime,
    required this.sizeBytes,
    required this.sha256,
    this.retentionPolicy = InboxRetentionPolicy.keep,
  });

  final String id;
  final String localPath;
  final String mime;
  final int sizeBytes;
  final String sha256;
  final InboxRetentionPolicy retentionPolicy;
}

/// One business event the model claims to have found in an [InboxItem].
///
/// [payloadJson] and [evidenceJson] are opaque here: the extraction layer owns
/// their schema. They are data, never instructions — this type deliberately
/// exposes no way to execute them.
class InboxExtractedEvent {
  const InboxExtractedEvent({
    required this.id,
    required this.itemId,
    required this.entityType,
    required this.certainty,
    required this.payloadJson,
    required this.evidenceJson,
    required this.extractionVersion,
  });

  final String id;
  final String itemId;
  final InboxEntityType entityType;

  /// How firmly the source supports this event. Never widened implicitly.
  final InboxCertainty certainty;

  /// JSON object of the entity's fields (title, dueAt, participants, ...).
  final String payloadJson;

  /// JSON array of `{attachmentId, quote}` source references.
  final String evidenceJson;

  /// Version of the extractor that produced this event, so a re-run can be
  /// distinguished from the original.
  final String extractionVersion;
}
