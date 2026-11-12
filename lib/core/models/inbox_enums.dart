/// Inbox persistence vocabulary.
///
/// The checkpointed values are the contract between three places that must
/// never drift apart: the Drift `CHECK` constraints, the domain enum parsing,
/// and the analysis pipeline's persisted `status`. Keep the `const` lists here
/// and derive the enums from them rather than restating the strings.
library;

/// Where an [InboxItem] came from.
///
/// The capture surfaces are the ones that already exist upstream: the Android
/// `ACTION_SEND`/`PROCESS_TEXT` receivers, the Windows clipboard/drag-drop/file
/// picker, and manual entry. `share` covers every Android system share.
enum InboxSourceType {
  share,
  processText,
  clipboard,
  dragDrop,
  filePicker,
  manual;

  /// Persisted spelling. Kept explicit so a renamed Dart identifier cannot
  /// silently rewrite existing rows.
  String get storageValue => switch (this) {
    InboxSourceType.share => 'share',
    InboxSourceType.processText => 'process_text',
    InboxSourceType.clipboard => 'clipboard',
    InboxSourceType.dragDrop => 'drag_drop',
    InboxSourceType.filePicker => 'file_picker',
    InboxSourceType.manual => 'manual',
  };

  static const storageValues = [
    'share',
    'process_text',
    'clipboard',
    'drag_drop',
    'file_picker',
    'manual',
  ];

  static InboxSourceType? tryParse(String? value) {
    for (final type in InboxSourceType.values) {
      if (type.storageValue == value) return type;
    }
    return null;
  }
}

/// Lifecycle of one captured [InboxItem].
///
/// Mirrors the approved design state machine:
/// `received -> preparing -> extracting -> reconciling -> proposed ->
/// approved/rejected -> executing -> succeeded/partial_failed/failed`.
///
/// A failure may be recorded from any in-flight state; the terminal "succeeded"
/// states are reachable only through [executing], so a rejected or failed item
/// can never be presented as having written anything.
enum InboxItemStatus {
  received,
  preparing,
  extracting,
  reconciling,
  proposed,
  approved,
  rejected,
  executing,
  succeeded,
  partialFailed,
  failed;

  String get storageValue => switch (this) {
    InboxItemStatus.received => 'received',
    InboxItemStatus.preparing => 'preparing',
    InboxItemStatus.extracting => 'extracting',
    InboxItemStatus.reconciling => 'reconciling',
    InboxItemStatus.proposed => 'proposed',
    InboxItemStatus.approved => 'approved',
    InboxItemStatus.rejected => 'rejected',
    InboxItemStatus.executing => 'executing',
    InboxItemStatus.succeeded => 'succeeded',
    InboxItemStatus.partialFailed => 'partial_failed',
    InboxItemStatus.failed => 'failed',
  };

  static const storageValues = [
    'received',
    'preparing',
    'extracting',
    'reconciling',
    'proposed',
    'approved',
    'rejected',
    'executing',
    'succeeded',
    'partial_failed',
    'failed',
  ];

  static InboxItemStatus? tryParse(String? value) {
    for (final status in InboxItemStatus.values) {
      if (status.storageValue == value) return status;
    }
    return null;
  }

  /// Whether analysis is currently in flight. Used to reject duplicate
  /// concurrent runs for the same item.
  bool get isProcessing =>
      this == InboxItemStatus.preparing ||
      this == InboxItemStatus.extracting ||
      this == InboxItemStatus.reconciling ||
      this == InboxItemStatus.executing;

  /// Whether this status is final for the current item revision. An item in a
  /// terminal state is re-analysed only after an explicit user action.
  bool get isTerminal =>
      this == InboxItemStatus.succeeded ||
      this == InboxItemStatus.partialFailed ||
      this == InboxItemStatus.failed ||
      this == InboxItemStatus.rejected;

  /// Legal next states. Anything else is a bug, not a recoverable situation.
  Set<InboxItemStatus> get allowedNext => switch (this) {
    InboxItemStatus.received => {InboxItemStatus.preparing},
    InboxItemStatus.preparing => {
      InboxItemStatus.extracting,
      InboxItemStatus.failed,
    },
    InboxItemStatus.extracting => {
      InboxItemStatus.reconciling,
      InboxItemStatus.failed,
    },
    InboxItemStatus.reconciling => {
      InboxItemStatus.proposed,
      InboxItemStatus.failed,
    },
    InboxItemStatus.proposed => {
      InboxItemStatus.approved,
      InboxItemStatus.rejected,
      InboxItemStatus.failed,
    },
    InboxItemStatus.approved => {
      InboxItemStatus.executing,
      InboxItemStatus.rejected,
    },
    InboxItemStatus.executing => {
      InboxItemStatus.succeeded,
      InboxItemStatus.partialFailed,
      InboxItemStatus.failed,
    },
    InboxItemStatus.succeeded => {},
    InboxItemStatus.partialFailed => {},
    InboxItemStatus.failed => {},
    InboxItemStatus.rejected => {},
  };

  bool canTransitionTo(InboxItemStatus next) =>
      allowedNext.contains(next) && next != this;
}

/// The business object an extracted event describes.
enum InboxEntityType {
  contact,
  opportunity,
  funding,
  meeting,
  task,
  note;

  String get storageValue => switch (this) {
    InboxEntityType.contact => 'contact',
    InboxEntityType.opportunity => 'opportunity',
    InboxEntityType.funding => 'funding',
    InboxEntityType.meeting => 'meeting',
    InboxEntityType.task => 'task',
    InboxEntityType.note => 'note',
  };

  static const storageValues = [
    'contact',
    'opportunity',
    'funding',
    'meeting',
    'task',
    'note',
  ];

  static InboxEntityType? tryParse(String? value) {
    for (final type in InboxEntityType.values) {
      if (type.storageValue == value) return type;
    }
    return null;
  }
}

/// How firmly the source text supports an extracted event.
///
/// This is the design's "事实 / 意向 / 预测 / 用户指令 / 待核实" distinction. It
/// exists so the UI can show what is asserted versus what the model inferred;
/// it must never be silently widened.
enum InboxCertainty {
  fact,
  intent,
  prediction,
  userInstruction,
  unverified;

  String get storageValue => switch (this) {
    InboxCertainty.fact => 'fact',
    InboxCertainty.intent => 'intent',
    InboxCertainty.prediction => 'prediction',
    InboxCertainty.userInstruction => 'user_instruction',
    InboxCertainty.unverified => 'unverified',
  };

  static const storageValues = [
    'fact',
    'intent',
    'prediction',
    'user_instruction',
    'unverified',
  ];

  static InboxCertainty? tryParse(String? value) {
    for (final certainty in InboxCertainty.values) {
      if (certainty.storageValue == value) return certainty;
    }
    return null;
  }
}

/// What to do with a captured attachment once extraction has finished.
enum InboxRetentionPolicy {
  keep,
  referenceOnly,
  deleteAfterProcessing;

  String get storageValue => switch (this) {
    InboxRetentionPolicy.keep => 'keep',
    InboxRetentionPolicy.referenceOnly => 'reference_only',
    InboxRetentionPolicy.deleteAfterProcessing => 'delete_after_processing',
  };

  static const storageValues = [
    'keep',
    'reference_only',
    'delete_after_processing',
  ];

  static InboxRetentionPolicy? tryParse(String? value) {
    for (final policy in InboxRetentionPolicy.values) {
      if (policy.storageValue == value) return policy;
    }
    return null;
  }
}
