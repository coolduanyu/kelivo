import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/models/inbox_enums.dart';
import '../../../core/models/inbox_item.dart';
import '../../../icons/lucide_adapter.dart' as lucide;
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/design_tokens.dart';

/// One row in the inbox list: what arrived, and how far it got.
///
/// The two things this widget must never blur together are "the AI suggested
/// something" and "an external tool was actually updated". [status] drives that
/// distinction with distinct wording and colour, so a captured item can never
/// read as executed.
class InboxItemTile extends StatelessWidget {
  const InboxItemTile({
    super.key,
    required this.item,
    required this.eventCount,
    this.onTap,
  });

  final InboxCapture item;
  final int eventCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _sourceIcon(item.sourceType),
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _titleFor(item, l10n),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: AppFontWeights.medium,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      InboxStatusChip(status: item.status),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        eventCount == 1
                            ? l10n.inboxEventCountOne
                            : l10n.inboxEventCountMany(eventCount),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _sourceIcon(InboxSourceType type) => switch (type) {
    InboxSourceType.share => lucide.Lucide.Share2,
    InboxSourceType.processText => lucide.Lucide.TextSelect,
    InboxSourceType.clipboard => lucide.Lucide.ClipboardPaste,
    InboxSourceType.dragDrop => lucide.Lucide.Upload,
    InboxSourceType.filePicker => lucide.Lucide.File,
    InboxSourceType.manual => lucide.Lucide.Pencil,
  };

  static String _titleFor(InboxCapture item, AppLocalizations l10n) {
    final text = item.rawText?.trim();
    if (text != null && text.isNotEmpty) return text;
    if (item.attachments.isNotEmpty) {
      return l10n.inboxAttachmentOnly(item.attachments.length);
    }
    return l10n.inboxUntitled;
  }
}

/// The status badge shown for an inbox item.
///
/// Colours and wording separate "waiting on the user" from "actually written",
/// which the design requires to be visually distinct.
class InboxStatusChip extends StatelessWidget {
  const InboxStatusChip({super.key, required this.status});

  final InboxItemStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final (label, color) = _appearance(l10n, theme.colorScheme);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: AppFontWeights.medium,
        ),
      ),
    );
  }

  (String, Color) _appearance(AppLocalizations l10n, ColorScheme cs) {
    return switch (status) {
      InboxItemStatus.received => (l10n.inboxStatusReceived, cs.onSurfaceVariant),
      InboxItemStatus.preparing ||
      InboxItemStatus.extracting ||
      InboxItemStatus.reconciling => (l10n.inboxStatusAnalyzing, cs.primary),
      InboxItemStatus.proposed => (l10n.inboxStatusNeedsReview, cs.tertiary),
      InboxItemStatus.approved ||
      InboxItemStatus.executing => (l10n.inboxStatusExecuting, cs.primary),
      InboxItemStatus.succeeded => (l10n.inboxStatusExecuted, cs.secondary),
      InboxItemStatus.partialFailed => (
        l10n.inboxStatusPartialFailure,
        cs.error,
      ),
      InboxItemStatus.failed || InboxItemStatus.rejected => (
        l10n.inboxStatusFailed,
        cs.error,
      ),
    };
  }
}

/// A reviewable action row: what will change, and whether it happened.
///
/// [executed] is deliberately separate from [approvalState]: an approved action
/// that has not run yet must not look like a completed one.
class InboxActionPreview extends StatelessWidget {
  const InboxActionPreview({
    super.key,
    required this.title,
    required this.connectorName,
    required this.operation,
    required this.approvalState,
    required this.risk,
    this.beforeValue,
    this.afterValue,
    this.executed = false,
    this.onApprovalChanged,
  });

  final String title;
  final String connectorName;
  final InboxOperation operation;
  final InboxApprovalState approvalState;
  final InboxRiskLevel risk;

  /// The current remote value, shown next to the proposal so a change is
  /// reviewable rather than blind.
  final String? beforeValue;
  final String? afterValue;

  final bool executed;
  final ValueChanged<InboxApprovalState>? onApprovalChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final cs = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: AppFontWeights.medium,
                  ),
                ),
              ),
              if (risk.requiresExplicitApproval)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.xs),
                  child: Icon(
                    lucide.Lucide.TriangleAlert,
                    size: 16,
                    color: cs.error,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${operation.storageValue} → $connectorName',
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          if (beforeValue != null || afterValue != null) ...[
            const SizedBox(height: AppSpacing.sm),
            InboxFieldDiff(before: beforeValue, after: afterValue),
          ],
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Text(
                executed
                    ? l10n.inboxActionExecuted
                    : _approvalLabel(l10n, approvalState),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: executed ? cs.secondary : cs.onSurfaceVariant,
                  fontWeight: AppFontWeights.medium,
                ),
              ),
              const Spacer(),
              if (!executed && onApprovalChanged != null)
                SegmentedButton<InboxApprovalState>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    ButtonSegment(
                      value: InboxApprovalState.approved,
                      label: Text(l10n.inboxApprove),
                    ),
                    ButtonSegment(
                      value: InboxApprovalState.rejected,
                      label: Text(l10n.inboxReject),
                    ),
                  ],
                  selected: {approvalState},
                  onSelectionChanged: (selection) =>
                      onApprovalChanged!(selection.first),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _approvalLabel(
    AppLocalizations l10n,
    InboxApprovalState state,
  ) => switch (state) {
    InboxApprovalState.pending => l10n.inboxApprovalPending,
    InboxApprovalState.approved => l10n.inboxApprovalApproved,
    InboxApprovalState.rejected => l10n.inboxApprovalRejected,
  };
}

/// A field-level before/after comparison.
class InboxFieldDiff extends StatelessWidget {
  const InboxFieldDiff({super.key, this.before, this.after});

  final String? before;
  final String? after;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final cs = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line(
          theme,
          l10n.inboxDiffBefore,
          before ?? l10n.inboxDiffEmpty,
          cs.onSurfaceVariant,
        ),
        const SizedBox(height: 2),
        _line(
          theme,
          l10n.inboxDiffAfter,
          after ?? l10n.inboxDiffEmpty,
          cs.primary,
        ),
      ],
    );
  }

  Widget _line(ThemeData theme, String label, String value, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// The Universal Inbox page: capture on top, items on the left, detail on the
/// right.
///
/// This is presentation only. It renders whatever the store and engine produced
/// and never invents an execution result.
class InboxPage extends StatelessWidget {
  const InboxPage({
    super.key,
    required this.items,
    required this.selectedItemId,
    required this.actions,
    this.onSelectItem,
    this.onPaste,
    this.onPickFile,
  });

  final List<InboxCapture> items;
  final String? selectedItemId;

  /// Actions for the selected item, if any were planned.
  final List<InboxActionPreviewData> actions;

  final ValueChanged<String>? onSelectItem;
  final VoidCallback? onPaste;
  final VoidCallback? onPickFile;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.inboxTitle)),
      body: Column(
        children: [
          InboxDropZone(onPaste: onPaste, onPickFile: onPickFile),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 320,
                  child: items.isEmpty
                      ? Center(
                          child: Text(
                            l10n.inboxEmpty,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final item = items[index];
                            return InboxItemTile(
                              item: item,
                              eventCount: 0,
                              onTap: onSelectItem == null
                                  ? null
                                  : () => onSelectItem!(item.id),
                            );
                          },
                        ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _detail(context, l10n),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context, AppLocalizations l10n) {
    if (selectedItemId == null) {
      return Center(child: Text(l10n.inboxSelectItem));
    }
    final item = items.where((i) => i.id == selectedItemId).firstOrNull;
    if (item == null) {
      return Center(child: Text(l10n.inboxSelectItem));
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.start,
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            _sectionTitle(context, l10n.inboxSourceSection),
            const SizedBox(height: AppSpacing.sm),
            Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.rawText?.trim().isNotEmpty == true
                    ? item.rawText!
                    : l10n.inboxAttachmentOnly(item.attachments.length),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '${item.timezone} · ${item.sourceType.storageValue}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.start,
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
          _sectionTitle(context, l10n.inboxProposalsSection),
          const SizedBox(height: AppSpacing.sm),
          actions.isEmpty
              ? Text(l10n.inboxNoProposals)
              : Column(
                  children: [
                    for (final action in actions)
                      InboxActionPreview(
                        title: action.title,
                        connectorName: action.connectorName,
                        operation: action.operation,
                        approvalState: action.approvalState,
                        risk: action.risk,
                        beforeValue: action.beforeValue,
                        afterValue: action.afterValue,
                        executed: action.executed,
                        onApprovalChanged: action.onApprovalChanged,
                      ),
                  ],
                ),
          ],
        ),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight: AppFontWeights.semibold,
      ),
    );
  }
}

/// Plain data for one proposal row, kept UI-free so the page can be rendered
/// in a golden test without a database or engine.
class InboxActionPreviewData {
  const InboxActionPreviewData({
    required this.title,
    required this.connectorName,
    required this.operation,
    required this.approvalState,
    required this.risk,
    this.beforeValue,
    this.afterValue,
    this.executed = false,
    this.onApprovalChanged,
  });

  final String title;
  final String connectorName;
  final InboxOperation operation;
  final InboxApprovalState approvalState;
  final InboxRiskLevel risk;
  final String? beforeValue;
  final String? afterValue;
  final bool executed;
  final ValueChanged<InboxApprovalState>? onApprovalChanged;
}

/// The capture strip at the top of the inbox.
class InboxDropZone extends StatelessWidget {
  const InboxDropZone({super.key, this.onPaste, this.onPickFile});

  final VoidCallback? onPaste;
  final VoidCallback? onPickFile;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.all(AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant,
          style: BorderStyle.solid,
        ),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.25),
      ),
      child: Row(
        children: [
          Icon(lucide.Lucide.FileArchive, color: cs.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              l10n.inboxDropHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onPaste,
            icon: const Icon(lucide.Lucide.ClipboardPaste, size: 16),
            label: Text(l10n.inboxPaste),
          ),
          const SizedBox(width: AppSpacing.xs),
          TextButton.icon(
            onPressed: onPickFile,
            icon: const Icon(lucide.Lucide.FilePlus, size: 16),
            label: Text(l10n.inboxPickFile),
          ),
        ],
      ),
    );
  }
}

/// Serialises a proposal list for logging/debugging without leaking secrets.
String encodeProposalsForLog(List<InboxActionPreviewData> actions) => jsonEncode([
  for (final action in actions)
    {
      'title': action.title,
      'connector': action.connectorName,
      'operation': action.operation.storageValue,
      'approval': action.approvalState.storageValue,
      'executed': action.executed,
    },
]);
