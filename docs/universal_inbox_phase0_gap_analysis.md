# Universal Inbox — 阶段 0 上游源码审计与差距分析

> 审计对象：[Kelivo](https://github.com/Chevey339/kelivo) `master` @ `27b8da938cfa7297323bc4267fbf52648ffda894`（2026-11-12）
> 审计方式：只读源码核验（`read` / `grep` / `glob`），逐条比对 `docs/` 与 `lib/` 的真实实现。
> 对应文档：`Kelivo_Universal_Inbox_PRD_Tech_Design_v0.1.md` §8「阶段 0：上游源码审计（开发前必须完成）」、§9「编码 Agent 开发纪律」、§10「未决且必须通过源码/运行测试确认」。
> 审计状态：**完成源码核验；编译与设备验证未完成**（见 §7 环境限制）。

## 0. 结论摘要（先读）

设计文档把它自己定义为「设计基线，尚未完成完整源码审计、编译和设备验证」，并要求「先源码核验，再修改本设计，再编码」「不通过则更新本设计而不是硬写代码」。本审计据此**先核验、后更新设计**，不在本轮硬写功能代码。

核验的总体结论：

1. **上游不是空项目，也不是设计文档假设的样子。** 多个 P0 输入通道（Android 分享、Windows 拖拽/粘贴/文件选择/全局热键）、结构化模型调用、审批、日志脱敏、备份加密、Drift 迁移等**已经存在并可复用**；但设计文档拟设的 **Connector 契约、安全凭证存储、与「聊天」并列的导航入口、统一收件箱数据模型** 在真实代码里**并不存在**。
2. **把拟设类型当成上游 API 会直接编译失败。** 例如 `supportsImages`/`supportsPdf`/`supportsJsonSchema`/`maxAttachmentSize`、`ConnectorManifest.search/get/execute/verify`、`secret_ref`、`go_router` 路由、与 Chat 并列的「收件箱」导航项，真实仓库里均无对应符号。
3. **§10 的 6 个「未决项」中，4 个已由源码给出确定答案（MCP 解耦、Office 支持、content:// 生命周期、凭证落盘/备份），1 个仍需运行/设备测试（跨设备幂等协调），1 个需产品决策（首批连接器选型与 API 限额）。** 详见 §6。
4. **因此本轮按 §8/§9 的门控停在设计更新**：产出本差距表与修订后的设计基线，而不是一个无法编译、无法通过 CI、也无法提供 Before/After 视觉证据的功能 PR。开工前还需补齐 §7 列出的环境与决策前提。

> 图例：`Verified` = 真实存在且符合假设；`Requires Adaptation` = 存在但形态不同、需改造/扩展；`Unsupported` = 缺失、需新建。

---

## 1. 模块 / 接口契约差距表（§4、§4.1、§4.2）

| 设计文档拟设 | 真实实现（精确路径 : 行） | 判定 | 说明 |
|---|---|---|---|
| `lib/features/universal_inbox/` 独立功能域，`pages/widgets/models/utils` | `AGENTS.md:9` 规定 `lib/features/<feature>/` 约定；该目录**不存在** | **Verified（约定）/ Requires Adaptation（落地）** | 约定成立，需新建目录并按 desktop/mobile 分栏 |
| `inbox_capture`：Share Intent / 剪贴板 / 拖拽 / 文件快照 | Android：`android/app/src/main/AndroidManifest.xml:76-88`（`ACTION_SEND`/`SEND_MULTIPLE`/`VIEW` `*/*`）；`android/app/src/main/kotlin/com/psyche/kelivo/MainActivity.kt:106,181`；`.../IncomingShareHandler.kt:26,62-97,130-141,214-229`（同步字节复制到 `filesDir/incoming_shares`，`share.json` 清单 + `acknowledgeShares` 回执）。Dart：`lib/core/services/incoming_share_service.dart:76,128-140,144-229`；消费点 `lib/features/home/pages/home_page.dart:590-691`。Windows：`pubspec.yaml:42 desktop_drop,43 hotkey_manager,79 file_picker,123 super_clipboard`；`home_page.dart:1633-1659`（`DropTarget`）；`lib/features/home/widgets/chat_input_bar.dart:2727-2889`（文本/图片/文件粘贴）；`windows/runner/flutter_window.cpp:203-347`（`app.clipboard`，WIC/CF_HDROP）；`lib/features/home/services/file_upload_service.dart:320-402`（`onPickFiles`/`onFilesDroppedDesktop`）；`lib/desktop/hotkeys/hotkey_event_bus.dart:4-21` | **Verified（输入通道）/ Requires Adaptation（复用）** | 通道已存在，但**全部汇入「聊天」草稿/新会话**，没有收件箱抽象；Android 复制在 Kotlin、Windows 复制在 Dart，缺统一事件模型 |
| `document_adapter`：MIME 检测、模型可接受表示 | `lib/core/models/chat_input_data.dart:5-44`（`DocumentAttachment{path,fileName,mime}`）；`lib/core/models/message_part.dart:232-346`（`ImagePart`/`FilePart`）；`lib/core/utils/multimodal_input_utils.dart:7,32-61`；`lib/utils/file_import_helper.dart:17-68`（sha256 去重复制） | **Requires Adaptation** | 已有附件模型，但无设计文档要求的「能力协商后选择表示」层 |
| `information_extractor`：结构化事件 + 来源引用 | `lib/core/services/api/chat_api_service.dart:49,315-343 sendMessageStream(...)、760-822 generateMessage/generateText` —— 全静态、无 `BuildContext`、无 chat provider 依赖；非聊天调用者 `lib/core/services/scheduled_task_text_executor.dart:172-192`、`lib/core/services/memory/memory_pipeline.dart:109`、`lib/features/translate/pages/translate_page.dart:138`、`lib/features/home/services/ocr_service.dart:136` | **Verified（可脱离 Chat UI 复用）** | 但仅提供「文本进 / 文本或流」出，无 0..N 事件、证据引用、certainty 状态模型；JSON schema 结构化输出只有 `ModelAbility.structuredOutput` 与 `$ref` 工具（`lib/core/services/api/json_schema_utils.dart`） |
| `entity_resolver`：名称消歧、外部对象查找、时间线 | 无对应模块；仅有 `lib/core/database/extension_entity_store.dart` 等扩展存储，无实体/别名/时间线 | **Unsupported** | 需新建（可复用 Drift 表） |
| `action_planner`：Diff / 冲突 / 风险 / 预览 | 无 diff/preview 管道；可复用片段：`lib/features/home/services/tool_approval_service.dart:63-211`（`requestApproval`/`approve`/`deny`）、`lib/core/services/scheduled_task_preparation.dart:5`（`ScheduledTaskPreparationStatus`）、`lib/features/scheduled_tasks/pages/scheduled_tasks_page.dart:282-289`（run 状态/预览渲染） | **Unsupported（完整模式）/ Verified（可复用片段）** | 设计文档要求的「逐字段原值/新值/置信度/证据」预览需新建 |
| `connector_registry` + Connector 契约 `connect/disconnect/describeCapabilities/search/get/execute/verify` + `read/search/create/update/append/delete` | 真实仅：`lib/core/providers/mcp_provider.dart:1663 connect,2319 disconnect,2958 callTool(serverId,toolName,args),2816 listTools,1304 setToolEnabled,1325 setToolNeedsApproval`；底层 `dependencies/mcp_client/lib/src/client/client.dart:376 listTools,391 callTool,482 listResources,499 readResource`；能力仅 `ServerCapabilities` 布尔 flags（`.../models/models.dart:1467`）。`lib/core/services/mcp/mcp_tool_service.dart:41-269` 的 `listAvailableToolsForConversation/callToolForAssistant/...` 全部需要 `ChatService`/`AssistantProvider`/`conversationId`。反例（非聊天调用）：`lib/core/services/search/providers/exa_mcp_search_service.dart:84-104` 直接 `Client.callTool` | **Unsupported（契约）/ Requires Adaptation（传输层）** | MCP 协议本身没有 CRUD 动词契约；`search/get/execute/verify` 与能力分类必须**从 tool name/schema 推断**或新建适配层。高层工具调用/审批与聊天绑定（见 §3） |
| `execution_engine`：幂等、状态机、批准、回执、重试 | 无；`lib/features/scheduled_tasks/` 有 run 状态/轮询（`scheduled_task_runner.dart:150-190`），但明确「Unattended runs cannot answer for the user」 | **Unsupported** | 需新建；`idempotencyKey`/回执表无现成实现 |
| `audit_store`：输入/提取/建议/审查/写入历史，Drift 迁移 | `lib/core/database/app_database.dart:774-808`（30 张表），`:822 currentSchemaVersion = 5`，`:826 publishedSchemaVersions={1,2,3,5}`（v4 从未发布），`:1016-1062 MigrationStrategy(onUpgrade: stepByStep(from1To2,from2To3,from3To5))`；`lib/core/database/schema_migrations.dart:28-50`「Adding a schema version」流程；`drift_schemas/app_database/drift_schema_v{1,2,3,5}.json`；`lib/core/database/app_database.g.dart`（已生成）；`pubspec.yaml:139 drift ^2.35.3,140 sqlite3,156 build_runner,157 drift_dev` | **Verified（机制）/ Requires Adaptation（新增表）** | 新增表 = bump 到 v6 + `from5To6` + 重新生成 + 快照；v4 跳过、快照冻结需注意 |
| 统一操作契约 `actionId/entityType/operation/fields/evidence/certainty/risk/approvalState/idempotencyKey` | 无任何对应符号 | **Unsupported** | 纯概念 schema，须新建并做业务类型校验 |

---

## 2. 输入 / 能力 / 数据模型差距

### 2.1 Android 分享与临时 URI

- `android/app/src/main/AndroidManifest.xml:76-81` 已声明 `ACTION_SEND` + `SEND_MULTIPLE` + `*/*`；`:71-75` `PROCESS_TEXT`；`:82-88` `VIEW content/file`。
- `IncomingShareHandler.kt:121-122` 注释明确：「copies bytes synchronously on a single background executor **while the sending activity's grant is still valid**」——即**不同过 `takePersistableUriPermission`，而是即时字节复制**，因此没有持久化授权失效问题。持久化授权只出现在无关的工作区 `ACTION_OPEN_DOCUMENT_TREE`（`.../workspace/WorkspaceDirectoryAccess.kt:92-93,124,154`）。
- **判定**：§10「Android 分享 `content://` 生命周期处理」= **Verified（已用即时复制解决，形态与文档设想的「保留引用 + 受控复制」不同 → Requires Adaptation）**。核心测试用例 5（关闭来源 App 后原件仍可访问）由即时字节复制天然满足。
- **缺口**：`PROCESS_TEXT` 是独立直插 composer 的通道（`lib/core/services/android_process_text.dart:5,25-34`）；无「专用 Capture 页 / 路由」；Android 侧 `home_page.dart:591` 用 `if (!PlatformUtils.isMobile) return` 门控，桌面不走 `IncomingShareService`。

### 2.2 Windows 输入

- 拖拽 `desktop_drop`（`home_page.dart:1633-1659` → `file_upload_service.dart:368-402`）、粘贴（`chat_input_bar.dart:2727-2889`，`super_clipboard` + 原生 `app.clipboard` CF_DIB/CF_HDROP）、文件选择（`file_picker`）、全局热键（`lib/core/providers/hotkey_provider.dart:253-290` `HotKeyScope.system`）**全部 Verified**。
- **缺口**：原生图片粘贴先写 OS 临时目录（`flutter_window.cpp:258-263` `pasted_<tick>.png`）再由 Dart 二次复制，未统一到受控暂存目录；`HotkeyAction`（`hotkey_event_bus.dart:4-21`）**没有「唤起收件箱」动作**，需新增。

### 2.3 Provider 能力矩阵（§4.3）

- 真实能力系统是 `lib/core/models/model_spec.dart:5 enum Modality {text,image,audio,video,pdf}、:7 enum ModelAbility {tool,reasoning,structuredOutput}、:607-673 ModelSpec（contextWindow/maxOutput）、:635 supportsTool、:639 supportsImageInput、:645 supportsPdfInput`；`lib/core/services/model_spec/model_spec_resolver.dart:180-229,391-405`；`lib/core/services/model_catalog/catalog_entry.dart:200-245`（`toolCall/reasoning/structuredOutput/attachment/inputModalities/contextLimit/inputLimit/outputLimit`）。
- **设计文档的 `supportsImages/supportsPdf/supportsOfficeFiles/supportsJsonSchema/supportsToolCall/maxAttachmentSize/maxInputTokens` 全部不存在**（全 `lib/` grep 零命中）。`CatalogModel.attachment`/`inputLimit` 为**死数据**（存了但无读取）。无 Office 能力位、无 JSON-schema 能力位、无每模型附件大小上限（只有硬编码 `claudeUploadSizeLimit = 100MB` `lib/core/services/api/providers/claude/claude_files.dart:24` 与 16MB 抽取上限）。
- **判定：Requires Adaptation** —— 复用 `Modality`/`ModelAbility`/`ModelSpec`，补充 Office/JSON-schema/size 能力位，清理死字段。

### 2.4 文件真实表示（§4.3 / 核心测试用例 6）

- 图片：**base64 inline data URL**，非 multipart 聊天（`lib/core/services/api/chat_api_helpers.dart:658-668,377-390`；`openai/chat_completions_api.dart:598-607`；`google_common.dart:482-488`；`openai/responses_request.dart:266`）。
- PDF：**默认文本抽取**（`lib/core/services/chat/document_text_extractor.dart:64-83` Syncfusion `PdfDocument`/`PdfTextExtractor`，注入 `## user sent a file:` 围栏块 `message_builder_service.dart:1491-1500`）；**原生 PDF** 仅当 `spec.supportsPdfInput`（`message_generation_service.dart:733-735` → `lib/core/services/api/native_input_attachments.dart:92-152`）。16MB 上限 `:61-63`。
- Office：**仅 DOCX**（`document_text_extractor.dart:89-92,128-156` ZipDecoder + `word/document.xml`）；`.doc` 明确 unsupported `:85-87`；**XLSX/PPTX/XLS 不在 `supportedExtensions`（`file_upload_service.dart:43-60`），无解析依赖**；XLSX 仅作为「sandbox data file」整文件交给官方 Claude 的 code-execution sandbox（`multimodal_input_utils.dart:43-61`、`builtin_tools.dart:683-707`），否则抛 `AttachmentRequiresWorkspace`。
- **判定**：PDF/Office 的轻量 Dart 降级路径 = **Verified**（`syncfusion_flutter_pdf:^31.2.5`、`archive:^4.5.2`、`xml:^6.5.0`，无 MinerU/服务端）；「XLSX 不能仅以截图替代」= **Verified**（根本无截图路径）**但 XLSX 解析本身 = Unsupported**。§10「Office 各格式原生多模态支持情况」答案：**仅 PDF 有原生输入位；DOCX 仅文本抽取；XLSX/PPTX 无解析、整文件交 sandbox**。
- 核心测试用例 6（模型不支持 PDF/Office 时明确降级）当前**部分满足**：有 16MB 上限与 `AttachmentRequiresWorkspace`，但没有面向收件箱的「能力协商 → 明确降级/报错」统一层。

### 2.5 数据模型（§5）

设计文档列出的 10 张表（`inbox_items/inbox_attachments/extracted_events/entities/entity_links/action_plans/planned_actions/execution_receipts/connector_configs/audit_events`）**全部不存在**。Drift 现有 30 张表均为聊天/设置/资产/MCP 相关（`app_database.dart:774-808`）。联合唯一索引、`entity_links.connector_id+external_id`、幂等键索引等约束须新建。

---

## 3. MCP 与「脱离聊天状态机」（§10 未决项 1）

- **传输层已解耦**：`McpProvider`（`lib/core/providers/mcp_provider.dart:444-457` 构造函数只依赖 `BusinessPreferences` + workspace/env，`lib/main.dart:960-965` 注册）**不 import chat**；`callTool` / `listTools` 无 chat 依赖；`exa_mcp_search_service.dart:84-104` 已是「非聊天功能直接调 MCP」的现成范例。
- **高层工具调用 / 发现 / 审批与聊天硬绑定**：`lib/core/services/mcp/mcp_tool_service.dart:7-8` import `chat_service.dart` / `assistant_provider.dart`，所有方法带 `ChatService`/`AssistantProvider`/`conversationId`；审批 `lib/features/home/services/tool_approval_service.dart:114-211` 以 `(conversationId, toolCallId)` 为键，UI 在 `lib/features/chat/widgets/chat_message_widget.dart:6612,6787,6807`；`lib/features/mcp/widgets/mcp_conversation_sheet.dart:5,36` `context.watch<ChatService>()`。
- **判定：Requires Adaptation（非 Verified 完全解耦）**。低层可直接复用，但设计文档要求的「Connector 只读查询 → 实体消歧 → 写执行」若走高层 `McpToolService`，必须先解耦出 chat-independent façade；或像 Exa 那样直接用 `Client.callTool`。
- 凭证：`docs/mcp-oauth.md:3,9-11`（授权码 + PKCE S256）；`lib/core/services/mcp/mcp_oauth_service.dart:94-158`（`accessToken/refreshToken`）；**与服务器配置、headers、STDIO env 一起明文存于 `BusinessPreferences` 键 `mcp_servers_v1`（`mcp_provider.dart:364,485-512,552-555`）**，非 keystore。

---

## 4. 凭证与数据安全（§7）

| 要求 | 真实实现 | 判定 |
|---|---|---|
| 凭证优先存 Windows Credential Manager / Android Keystore，业务库只存 `secret_ref` | `pubspec.yaml` **无** `flutter_secure_storage`/keystore/keychain/biometric 依赖；`lib/secrets/` 仅 `fallback.dart:1` 硬编码占位 key。真实落盘：`settings_provider.dart:3117-3123 setProviderConfig → prefs.setString('provider_configs_v1', jsonEncode(map))` → `business_preferences.dart:140,166-213` → `business_settings_router.dart` → `business_repository.dart:426-433 INSERT INTO provider_rows(payload)`；`settings_provider.dart:6306-6657` `ProviderConfig.toJson` 明文 `apiKey/oauthCredentials/serviceAccountJson/proxyPassword/apiKeys`；`lib/core/models/provider_oauth.dart:55,113-125` 注释「Stored with the provider configuration, including in portable backups」；`docs/provider-oauth.md:20` 明确「明文保存在供应商配置中，包含在设置备份、导出和恢复中」 | **Unsupported** —— 无依赖、无抽象、无 `secret_ref`，全仓库 grep `secret_ref` / `CredentialManager` / `AndroidKeyStore` / `keychain` / `secure_storage` 零命中 |
| 默认导出/分享剔除凭证，含密钥备份须明确选择且加密 | `lib/core/models/backup_scope.dart:19,21`「New categories are enabled by default」、`excluded` 默认空 ⇒ providers 默认全含；`lib/core/database/backup_content_filter.dart:18-23` 所有 `provider*` 归入 providers；`lib/core/services/backup/data_sync.dart:3243-3257` 与 `business_settings_router.dart:295-319,577-626,877-902`（校验时明确识别 `apiKey/accessToken/refreshToken`）**逐字导出**。无 `includeCredentials/stripCredentials` 概念（全仓零命中）。**仅**存在「用户可选、整文件」AES-256-GCM + Argon2id 加密：`lib/core/services/backup/backup_encryption.dart:21-31,59`，`settings_provider.dart:1490 ?? false` | **Unsupported（默认剔除）/ Verified（可选整文件加密）** |
| 日志/调试面板/错误报告屏蔽 Token、敏感 Headers | `lib/core/services/logging/log_redactor.dart:3-122`（敏感头 `authorization/x-api-key/cookie`、`sk-`/`AIza`/`AKIA` 等前缀、`***(len=N)`）；`dio_http_client.dart:194-426`、`flutter_logger.dart:136`、`provider_oauth_adapter.dart:163` 全链路接入 | **Verified**（best-effort 正则，非穷尽） |
| 外部文本提示词注入隔离 | `lib/features/instruction_injection/` 仅 1 个 CRUD 页面 + `instruction_injection_provider.dart:45-50` 直接把用户片段 `.map(trim)` 拼接进 system prompt；无 delimiter/untrusted/sanitize/escape（全仓 grep 零命中） | **Unsupported** —— 这是「用户主动注入」而非防御边界；核心测试用例 10 需新建隔离层 |
| 最小权限 / 确认写入目标 | 仅 `ToolApprovalService` + `lib/core/services/conversation_tool_permissions.dart:133-214`（`ToolPermissionMode.requestApproval/fullAccess`） | **Requires Adaptation** |

---

## 5. UX 与集成（§6）

- **桌面**：`lib/desktop/desktop_home_page.dart:43` `int _tabIndex // 0=Chat,1=Translate,2=Storage,3=Settings`；`:277-295` `IndexedStack` 4 个硬编码 child；`:320-328` `DesktopNavRail`；`lib/desktop/desktop_nav_rail.dart:27,57-102` 每个 `_CircleAction` 单独硬编码；`:56` `clamp(0,3)`。新增「与聊天并列」项须同时改这两个文件、索引注释、clamp 与 l10n tooltip。
- **移动**：`lib/features/home/pages/home_mobile_layout.dart:93-140` 只有 `InteractiveDrawer` + `SideDrawer`，**没有 bottom nav / 顶层目的地列表**；非聊天入口是 `side_drawer.dart:2889-2923` 两个图标 + `Navigator.push`（`settings_page.dart:291,359`）。
- **路由**：`go_router` **不在 `pubspec.yaml`、全 `lib/` 零使用**；`main.dart:1210-1223` `MaterialApp.home` + `main.dart:1360-1368` 按平台切 `DesktopHomePage`/`HomePage` + 命令式 `Navigator.push`。设计文档假设的「路由声明」是错的。
- **判定**：「新增 `lib/features/universal_inbox/` + desktop/mobile 分栏」= **Verified（AGENTS.md:9,10,61 约定）/ Requires Adaptation**（真实分栏走 `home_page.dart:753-792` `MediaQuery + AppBreakpoints.tablet + isDesktopPlatform`，`ResponsiveHelper`（`screen_type_helper.dart:4-13`）只有 4 个静态方法、home 未用它）；「与聊天并列的导航项」= **Requires Adaptation / 部分 Unsupported**（桌面固定 4 槽 + 移动无列表，两套机制各改一遍）；「go_router」= **Unsupported**。
- **i18n**：`lib/l10n/` 7 个 ARB（en/zh 双源 + zh_Hans/zh_Hant/ko/ru/tr，各 4913 键），5 个 supportedLocales / 6 个 UI 语言；`l10n.yaml`；`tool/l10n/translate.py sync/check` + `flutter gen-l10n`；AGENTS.md:13 要求每个英文键带 `@key.description`。
- **共享组件**：`lib/shared/widgets/` 67 个（SectionCard/CustomBottomSheet/IosFormTextField/IosCheckbox/InteractiveDrawer…）；`lib/shared/dialogs/` 1 个；图标必须 `lucide_icons_flutter`（AGENTS.md:59）；**桌面禁用 bottom sheet**（AGENTS.md:58）。
- **CI**：`.github/workflows/pr-check.yml`（Flutter 3.47.6）：`dart format`（仅改动文件）、`flutter gen-l10n` + `git diff --exit-code -- lib/l10n`、`translate.py check`、l10n 工具单测、`dart analyze --fatal-infos lib test integration_test tool`、`flutter test`（全量）、markstream 同样跑。**PR 不触发 Windows/Android 构建**（`build.yml`/`build-stable*.yml` 均为 `workflow_dispatch`，`flutter build apk/windows`）。

---

## 6. §10 六个「未决项」——源码给出的答案

| 未决项 | 结论 | 依据 |
|---|---|---|
| 1. MCP 能否完全脱离聊天状态机运行 | **否（Requires Adaptation）**：传输层可（`McpProvider.callTool` + Exa 范例），高层 `McpToolService`/审批/`ToolApprovalService` 与 chat 绑定；`describeCapabilities/search/get/execute/verify` façade 不存在 | §3 |
| 2. Office 各格式原生多模态支持 | **PDF 有原生输入位；DOCX 仅文本抽取；XLSX/PPTX 无解析、整文件交官方 Claude sandbox**；能力位无 Office 项 | §2.3/§2.4 |
| 3. Android 分享 `content://` 生命周期 | **已用「即时字节复制 + share.json 回执」解决**，无持久授权、无失效风险；`PROCESS_TEXT` 为另一独立通道 | §2.1 |
| 4. 当前凭证实际落盘与备份路径 | **明文 JSON 在 `provider_rows.payload`（kelivo.db）**，经 `BusinessPreferences`；备份/导出/分享/恢复全含；仅可选整文件 AES 加密 | §4 |
| 5. 跨设备对同一外部对象的幂等键协调 | **源码无此机制**（`idempotencyKey`/`entity_links`/`execution_receipts` 均不存在）；设计文档 V1 非目标「不要求 Windows/Android 本地库实时同步」，但外部对象幂等仍须新建。**本项仍需运行/设备测试来确定外部 API 的幂等语义** | §1/§2.5 |
| 6. 首批两个连接器实际选择与 API 限额 | **源码无法回答**：真实 MCP 无 CRUD 契约，Connector 未定；须由产品决策 + 目标软件 API 实测 | §1 |

---

## 7. 本轮为何停在「更新设计」而非硬写代码（§8/§9 门控）

设计文档 §8 明确「**阶段 0：上游源码审计（开发前必须完成）**……输出差距表和真实文件路径，**不通过则更新本设计而不是硬写代码**」；§9 规定「**先源码核验，再修改本设计，再编码**；不得将本文件的拟设类型当作上游实际 API」「遵守上游 AGENTS.md：`dart analyze`、`flutter test`」「小步提交：数据迁移 → 事件 Schema → Provider 桥接 → Inbox UI → Connector → 执行闭环；每步给出测试和差异说明」。本审计已核验出多处 **Unsupported / Requires Adaptation**，按文档自身规则必须先更新设计。

此外本执行环境存在**硬约束**，使「可编译、可测、可视觉验证」的功能 PR 在当前不可能完成：

1. **无 Flutter / Dart SDK**：`flutter`、`dart`、`fvm`、pub-cache 均不存在；无法 `dart analyze`、`flutter test`、`flutter build`、`dart run build_runner`（Drift 代码生成）、`flutter gen-l10n`。
2. **无法生成 UI 视觉证据**：交付要求「每个改 UI 的 PR 必须含 Before/After 实际截图」；本机无 SDK 即无法启动应用截图，任何 UI 改动都无法合规验收。
3. **无法完成 §8 要求的「编译和设备验证」**：Windows 安装包 / Android APK 构建与核心测试用例 5、9、10 的设备实测均需 SDK + 设备/模拟器 + 目标软件账号。
4. **设计文档仍含 6 项未决的产品/API 决策**（§10），尤其「首批两个连接器实际选择与 API 限额」「跨设备幂等键协调」不是编码 Agent 可自行拍板的（§9 纪律、§1 非目标）。

**因此本轮交付**：本差距分析 + 对设计基线的修订（把拟设类型改为真实 API、把 Unsupported 项列为需先决策/新建、把 §10 已答项固化）。**未交付**：任何 `lib/` 功能代码、Drift 迁移、UI、Connector、执行引擎。

### 后续开工前需补齐的前提

- [ ] 安装 Flutter 3.47.6（与 `pr-check.yml` 对齐）与 Dart SDK、`flutter pub get --enforce-lockfile`、可运行 `dart analyze` / `flutter test` / `build_runner` / `gen-l10n` 的环境。
- [ ] 由需求方确认 §10 未决项 5/6（连接器选型、外部幂等语义、API 限额）与 §7 安全存储迁移是否纳入 V0/V1 及增量迁移策略（不造成现有账号失效）。
- [ ] 确认 AGPL-3.0 分发附带源码义务（§9.6）。
- [ ] 按修订后的设计，以「数据迁移 → 事件 Schema → Provider 桥接 → Inbox UI → Connector → 执行闭环」小步提交，每步带 `dart analyze` + 相关 `flutter test` + Before/After 视觉证据。

---

## 8. 对设计文档 v0.1 的修订建议（据此更新设计，而非重写代码）

1. **§4 模块表**：把「建议放在 `lib/features/universal_inbox/`」保留，但把每行「与上游边界」改为上表 1 的真实路径；把 `connector_registry`/`execution_engine`/`audit_store` 标注为 **新建**，把 `information_extractor`/`document_adapter` 标注为 **复用 `ChatApiService` / `ModelSpec` / `DocumentAttachment` + 扩展**。
2. **§4.1**：注明统一操作契约为**待建概念**，不是上游 API；`fields` 校验须自建，不得直发模型自由文本。
3. **§4.2 Connector 契约**：改为「以 MCP `Client.callTool/listTools` 为唯一传输层；`search/get/execute/verify` 与 CRUD 能力为**适配层推断/新建**；高层调用需先解耦 chat 依赖；凭证目前明文，安全存储为新增项」。删除「MCP 作为其中一种传输」外对 `describeCapabilities` 的现成假设。
4. **§4.3 能力矩阵**：字段名对齐 `Modality/ModelAbility/ModelSpec`（`supportsImageInput/supportsPdfInput/supportsTool/structuredOutput/contextWindow/maxOutput`），把 Office/JSON-schema/maxAttachmentSize 列为**需新增**；清理 `CatalogModel.attachment` 死数据。
5. **§5 数据模型**：10 张表全部标为**待建**，并写明 Drift v5→v6 的 `from5To6` + `schema dump/generate/steps` 流程与 v4 跳过的约束。
6. **§6 UX**：把「导航栏增加收件箱」改为「桌面改 `IndexedStack` + `DesktopNavRail` 两处硬编码；移动改 `SideDrawer`/`Navigator.push`；无 go_router」；补「桌面禁 bottom sheet、图标用 lucide、l10n 双源 ARB + gen-l10n」。
7. **§7 安全**：把「优先存 keystore / 只存 secret_ref / 默认导出剔除」从「最小要求」改为「**当前 Unsupported 的改造项 + 增量迁移计划**」；保留「日志脱敏已 Verified」；新增「提示词注入隔离需新建」。
8. **§8/§10**：把 §6 的六个答案写回「未决项」，仅保留「跨设备幂等协调」「连接器选型/限额」为真正待运行/产品决策项；把「编译与设备验证」列为开工门槛而非已完成项。

---

## 9. 核验方法

- 锁定 commit：`git rev-parse HEAD` = `27b8da938cfa7297323bc4267fbf52648ffda894`。
- 全部结论来自对 `repo/` 内 `lib/`、`android/`、`windows/`、`docs/`、`pubspec.yaml`、`.github/workflows/` 的只读检索与逐文件阅读；关键结论已用 `read`/`sed` 二次抽查（`desktop_home_page.dart:277-295`、`desktop_nav_rail.dart:27`、`chat_api_service.dart:315/761`、`model_spec.dart:5,7,635-645`、`document_text_extractor.dart:61,71,86`、`app_database.dart:774-822,1016-1062`、`pr-check.yml`）。
- 本轮**未修改** `lib/`、`android/`、`windows/`、`pubspec.yaml` 等任何源码；唯一新增文件为本文档。
- 上游 `AGENTS.md`（真实文件，首行标题为 `# AFENTS.md` 拼写）与 `CLAUDE.md`（`@AGENTS.md`）已读。
