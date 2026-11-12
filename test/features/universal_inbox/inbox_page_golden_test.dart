import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/inbox_enums.dart';
import 'package:Kelivo/core/models/inbox_item.dart';
import 'package:Kelivo/features/universal_inbox/pages/inbox_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

/// Renders the Universal Inbox page headlessly and writes reference images.
///
/// This is how the delivered Before/After evidence is produced: the machine has
/// no display server, so a real widget render through `flutter_test`'s Skia
/// pipeline is used instead of a running desktop window. The widget tree, theme
/// and localisations are the real ones.
///
/// Run with `--update-goldens` to regenerate:
///   flutter test test/features/universal_inbox/inbox_page_golden_test.dart \
///     --update-goldens
void main() {
  ByteData? cjkBytes;
  ByteData? iconBytes;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fontFile = File('/usr/share/fonts/truetype/custom/彩虹楷体.ttf');
    final fallback = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
    final source = fontFile.existsSync()
        ? fontFile
        : (fallback.existsSync() ? fallback : null);
    if (source != null) {
      cjkBytes = ByteData.sublistView(await source.readAsBytes());
    }
    iconBytes = await rootBundle.load(
      'packages/lucide_icons_flutter/assets/lucide.ttf',
    );
  });

  var fontsLoaded = false;

  /// Loads the render fonts inside the test body.
  ///
  /// `setUpAll` runs before the per-test font collection is installed, so a
  /// FontLoader there has no effect on the rendered image; loading here does.
  /// Registers the already-loaded font bytes.
  ///
  /// FontLoader has to run after the per-test font collection exists, so this
  /// is invoked from the test body under [WidgetTester.runAsync] rather than
  /// from `setUpAll`.
  Future<void> loadFonts() async {
    if (fontsLoaded) return;
    fontsLoaded = true;
    final cjk = cjkBytes;
    if (cjk != null) {
      for (final family in ['Roboto', 'sans-serif', '.SF UI Text']) {
        final loader = FontLoader(family)..addFont(Future.value(cjk));
        await loader.load();
      }
    }
    final icons = iconBytes;
    if (icons != null) {
      // IconData from the package resolves through the packaged family name,
      // but registering the bare name too keeps it working if that changes.
      for (final family in const [
        'packages/lucide_icons_flutter/Lucide',
        'Lucide',
      ]) {
        final iconLoader = FontLoader(family)..addFont(Future.value(icons));
        await iconLoader.load();
      }
    }
  }

  Widget harness(Widget child) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B6FF5),
          brightness: Brightness.light,
        ),
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: child,
    );
  }

  InboxCapture item({
    required String id,
    required String text,
    InboxItemStatus status = InboxItemStatus.proposed,
    InboxSourceType source = InboxSourceType.share,
  }) {
    return InboxCapture(
      id: id,
      sourceType: source,
      rawText: text,
      contentHash: 'hash-$id',
      capturedAt: DateTime.utc(2026, 11, 12, 9),
      timezone: 'Asia/Dubai',
      status: status,
    );
  }

  Future<void> pumpAt(WidgetTester tester, Widget child, Size size) async {
    await tester.runAsync(loadFonts);
    tester.view.physicalSize = size * 3; // 3x for crisp images
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(child));
    await tester.pumpAndSettle();
  }

  testWidgets('golden: inbox with proposals', (tester) async {
    final items = [
      item(
        id: 'item-1',
        text: '王总说下周五前把融资方案发给他，顺便约一下周四下午的会',
      ),
      item(
        id: 'item-2',
        text: '季度复盘会议纪要：确认了三个待办',
        status: InboxItemStatus.succeeded,
        source: InboxSourceType.clipboard,
      ),
    ];

    await pumpAt(
      tester,
      InboxPage(
        items: items,
        selectedItemId: 'item-1',
        actions: const [
          InboxActionPreviewData(
            title: '准备融资方案并发送给王总',
            connectorName: 'Google 日历',
            operation: InboxOperation.create,
            approvalState: InboxApprovalState.pending,
            risk: InboxRiskLevel.normal,
            afterValue: '2026-11-20 18:00 (+04:00)',
          ),
          InboxActionPreviewData(
            title: '与王总开会',
            connectorName: 'Google 日历',
            operation: InboxOperation.create,
            approvalState: InboxApprovalState.pending,
            risk: InboxRiskLevel.elevated,
            afterValue: '2026-11-19 15:00 (+04:00)',
          ),
        ],
      ),
      const Size(1200, 800),
    );

    await expectLater(
      find.byType(InboxPage),
      matchesGoldenFile('goldens/inbox_with_proposals.png'),
    );
  });

  testWidgets('golden: inbox empty state', (tester) async {
    await pumpAt(
      tester,
      const InboxPage(items: [], selectedItemId: null, actions: []),
      const Size(1200, 800),
    );

    await expectLater(
      find.byType(InboxPage),
      matchesGoldenFile('goldens/inbox_empty.png'),
    );
  });

  testWidgets('golden: executed action is visually distinct', (tester) async {
    await pumpAt(
      tester,
      InboxPage(
        items: [
          item(
            id: 'item-1',
            text: '王总说下周五前把融资方案发给他',
            status: InboxItemStatus.succeeded,
          ),
        ],
        selectedItemId: 'item-1',
        actions: const [
          InboxActionPreviewData(
            title: '准备融资方案并发送给王总',
            connectorName: 'Google 日历',
            operation: InboxOperation.create,
            approvalState: InboxApprovalState.approved,
            risk: InboxRiskLevel.normal,
            beforeValue: '（无）',
            afterValue: '2026-11-20 18:00 (+04:00)',
            executed: true,
          ),
        ],
      ),
      const Size(1200, 800),
    );

    await expectLater(
      find.byType(InboxPage),
      matchesGoldenFile('goldens/inbox_executed.png'),
    );
  });
}
