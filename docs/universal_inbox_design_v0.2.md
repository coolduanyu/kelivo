# Kelivo Universal Inbox 需求与技术设计 v0.2（源码落地版）

> 版本：v0.2（2026-11-12）  
> 状态：**阶段 0 源码审计完成；已按审计结果修正 v0.1 的技术假设；仍未编译、未做设备验证，未进入编码。**  
> 基线：[universal_inbox_design_v0.1.md](universal_inbox_design_v0.1.md)（产品定位、用户旅程、UX 意图、测试用例仍以 v0.1 为准，本文件不重复）  
> 依据：[universal_inbox_phase0_gap_analysis.md](universal_inbox_phase0_gap_analysis.md)（差距表、真实路径、核验方法）  
> 审计锁定 commit：`27b8da938cfa7297323bc4267fbf52648ffda894`（Chevey339/kelivo `master`）

## 0. 本版改了什么

v0.1 把它自己定义为「设计基线，尚未完成完整源码审计」，并在 §4/§5/§7 中给出一批**拟建接口与概念 schema**。阶段 0 审计证实其中大部分在上游并不存在（`Unsupported`）或形态不同（`Requires Adaptation`）。按 v0.1 §8「不通过则更新本设计而不是硬写代码」、§9.1「先源码核验，再修改本设计，再编码；不得将本文件的拟设类型当作上游实际 API」，本版做两件事：

1. 把「拟设类型」全部替换为**已核验的真实 API / 文件路径**，并明确标注哪些是**复用**、哪些是**新建**。
2. 把 v0.1 §10 中源码可回答的未决项固化，保留真正需要产品/运行决策的未决项，**不代替需求方拍板**。

产品范围（§1 定位与边界、§2 用户旅程与优先级、§6 UX 意图、§8 核心测试用例、§7 安全目标）**保持不变**；本版只修正技术契约与施工前提。

---

## 1. 真实架构与落点（替代 v0.1 §4 模块表）

约定（已核验）：`AGENTS.md:9` 功能域 `lib/features/<feature>/`（`pages/widgets/models/utils`）；`:10,:61` desktop/mobile 分栏；`:11` Provider；`:12` Drift + `drift_schemas/`；`:13` l10n 双源 ARB。

| v0.1 模块 | 落地判定 | 真实落点 / 复用点 |
|---|---|---|
| `inbox_capture` | **复用 + 新建统一层** | Android `android/app/src/main/kotlin/com/psyche/kelivo/IncomingShareHandler.kt`（即时字节复制 + `share.json` 回执）、`lib/core/services/incoming_share_service.dart`；Windows `lib/features/home/pages/home_page.dart:1633-1659`（`DropTarget`）、`lib/features/home/widgets/chat_input_bar.dart:2727-2889`（粘贴）、`lib/features/home/services/file_upload_service.dart:320-402`（文件选择/拖拽）、`lib/desktop/hotkeys/`（热键）。当前全部汇入聊天草稿；需新建 `lib/features/universal_inbox/` 下的统一 `InboxItem` 接入层，把这些入口改道到收件箱 |
| `document_adapter` | **复用** | `lib/core/models/chat_input_data.dart:5-44`（`DocumentAttachment`）、`lib/core/models/message_part.dart:232-346`、`lib/core/utils/multimodal_input_utils.dart`、`lib/utils/file_import_helper.dart:17-68`（sha256 去重复制）。能力协商层需新建 |
| `information_extractor` | **复用模型调用 + 新建抽取层** | `lib/core/services/api/chat_api_service.dart:49,315-343 sendMessageStream(...),760-822 generateMessage/generateText`（全静态、无 chat UI 依赖，已有 `scheduled_task_text_executor.dart:172-192` 等非聊天调用者）。「0..N 事件 + 证据引用 + certainty 状态」为新建 |
| `entity_resolver` | **新建** | 无现成模块；可复用 `lib/core/database/extension_entity_store.dart` 与 Drift 表 |
| `action_planner` | **新建 + 复用审批片段** | 无 diff/preview 管道；复用 `lib/features/home/services/tool_approval_service.dart:63-211`、`lib/core/services/scheduled_task_preparation.dart:5`、`lib/features/scheduled_tasks/pages/scheduled_tasks_page.dart:282-289` 的状态/预览渲染 |
| `connector_registry` | **新建适配层（契约 Unsupported）** | 传输层复用 `lib/core/providers/mcp_provider.dart:2958 callTool / :2816 listTools / :1663 connect / :2319 disconnect` 与底层 `dependencies/mcp_client/lib/src/client/client.dart:376,391`；非聊天直调范例 `lib/core/services/search/providers/exa_mcp_search_service.dart:84-104`。`describeCapabilities/search/get/execute/verify` 与 CRUD 能力分类**不存在**，须由 tool name/schema 推断或新建适配层；高层 `lib/core/services/mcp/mcp_tool_service.dart:41-269` 与 `ToolApprovalService` 绑定 chat，需先解耦 |
| `execution_engine` | **新建** | 无幂等/状态机/回执实现；`idempotencyKey`、`execution_receipts` 均需新建 |
| `audit_store` | **复用迁移机制 + 新建表** | `lib/core/database/app_database.dart:774-808`（30 表）、`:822 currentSchemaVersion = 5`、`:826 publishedSchemaVersions={1,2,3,5}`（v4 从未发布）、`:1016-1062 stepByStep(from1To2,from2To3,from3To5)`；`lib/core/database/schema_migrations.dart:28-50`「Adding a schema version」流程；`drift_schemas/app_database/drift_schema_v{1,2,3,5}.json` |

### 1.1 统一操作契约（v0.1 §4.1）

v0.1 的 `actionId/sourceItemId/entityType/operation/fields/evidence/certainty/risk/approvalState/idempotencyKey` 是**概念 schema，上游无对应符号**。保留为内部契约，但必须：

- 新建 Dart 类型 + 按业务类型的 `fields` schema 校验，**不得把模型自由文本直发 Connector**；
- `certainty` 五态（事实/意向/预测/用户指令/待核实）与 `evidence` 引用新建；
- 业务日期保留原始时区与解释依据（v0.1 §4.1 约束不变）。

### 1.2 Connector 契约（v0.1 §4.2）—— 修正

- **删除**「`ConnectorManifest` 已含 `search/get/execute/verify` 与 `read/search/create/update/append/delete` 能力」的假设。真实 MCP `ServerCapabilities`（`dependencies/mcp_client/lib/src/models/models.dart:1467`）只有 `tools/resources/prompts/logging` 布尔位；协议无 CRUD 动词。
- **改为**：以 `McpProvider.callTool` / `mcp.Client.callTool` 为传输层；`search/get/execute/verify` 由适配层按具体 tool schema 映射；能力声明（能否 `search`/`get`）必须**显式探测并降级**——若目标工具只有 `create` 而无 `search`/`get`，按 v0.1 §4.2 降低自动化级别并提示重复创建风险（该约束仍有效）。
- **审批**：现有 `ToolApprovalService` 以 `(conversationId, toolCallId)` 为键、UI 在 `chat_message_widget.dart`，**不可直接复用给收件箱**；需新建 chat-independent 审批模型，或保留 `McpProvider.setToolNeedsApproval` 的 per-tool 开关并另建审批队列。
- **凭证**：MCP OAuth/headers/env 现明文存于 `BusinessPreferences` 键 `mcp_servers_v1`（`mcp_provider.dart:364,485-512,552-555`）；新建 Connector 配置表时按 §3 处理 `secret_ref`。

### 1.3 Provider 能力矩阵（v0.1 §4.3）—— 修正

真实能力系统（`lib/core/models/model_spec.dart`）：

- `enum Modality { text, image, audio, video, pdf }`（`:5`）、`enum ModelAbility { tool, reasoning, structuredOutput }`（`:7`）；
- `ModelSpec`（`:607-673`）：`contextWindow` / `maxOutput`、`supportsTool`（`:635`）、`supportsImageInput`（`:639`）、`supportsPdfInput`（`:645`）；
- 解析：`lib/core/services/model_spec/model_spec_resolver.dart:180-229,391-405`；目录源 `lib/core/services/model_catalog/catalog_entry.dart:200-245`（`toolCall/reasoning/structuredOutput/attachment/inputModalities/contextLimit/inputLimit/outputLimit`）。

**v0.1 的 `supportsImages/supportsPdf/supportsOfficeFiles/supportsJsonSchema/supportsToolCall/maxAttachmentSize/maxInputTokens` 均不存在**；`CatalogModel.attachment`/`inputLimit` 为死数据。设计改为：复用上述真实字段，**新增** Office 能力位、JSON-schema/结构化输出能力位、每模型附件大小上限（现有硬编码仅 `claude_files.dart:24` 100MB 与 `document_text_extractor.dart:61` 16MB）。

### 1.4 文件真实表示（v0.1 §4.3 / 测试用例 6）—— 修正

- 图片：base64 inline data URL（`chat_api_helpers.dart:658-668,377-390`；`openai/chat_completions_api.dart:598-607`；`google_common.dart:482-488`；`openai/responses_request.dart:266`）。
- PDF：默认 Syncfusion 文本抽取（`lib/core/services/chat/document_text_extractor.dart:64-83`，注入 `## user sent a file:` 围栏块 `message_builder_service.dart:1491-1500`）；`spec.supportsPdfInput` 时走原生（`message_generation_service.dart:733-735` → `native_input_attachments.dart:92-152`）。16MB 上限。
- Office：**仅 DOCX** 文本抽取（`document_text_extractor.dart:89-92,128-156`）；`.doc` 明确 unsupported（`:85-87`）；**XLSX/PPTX 不在 `supportedExtensions`（`file_upload_service.dart:43-60`）、无解析依赖**，仅整文件交官方 Claude code-execution sandbox（`multimodal_input_utils.dart:43-61`、`builtin_tools.dart:683-707`）。
- 轻量 Dart 降级（无 MinerU / 无第二模型）**已成立**（`syncfusion_flutter_pdf`、`archive`、`xml`）；「XLSX 不能仅以截图替代」也成立（无截图路径）——**但 XLSX 解析本身缺失，须新建**才能满足 v0.1 阶段 2 的 DOCX/XLSX/PPTX 覆盖。

---

## 2. 数据模型（替代 v0.1 §5）

v0.1 的 10 张表（`inbox_items` / `inbox_attachments` / `extracted_events` / `entities` / `entity_links` / `action_plans` / `planned_actions` / `execution_receipts` / `connector_configs` / `audit_events`）**全部不存在**，保持为待建目标。

施工约束（已核验）：

- `currentSchemaVersion = 5`，`publishedSchemaVersions = {1,2,3,5}`，**v4 从未发布**；新增表走 v5 → v6 的 `from5To6`，按 `schema_migrations.dart:28-50` 用 `drift_dev schema dump/generate/steps` 生成，更新 `drift_schemas/` 快照与 `_validateRawSchema`；`stepByStep` 不自动建索引（`:1045` 注释），需显式 `m.createIndex`。
- 生成物 `lib/core/database/app_database.g.dart` 已提交，改表后须 `dart run build_runner build` 重新生成（**本环境无 SDK，见 §5**）。
- v0.1 §5 的约束仍全部保留：原始内容与模型输出不可直接成为执行指令；配置/审计与 Token 分离；`entity_links.connector_id + external_id` 联合唯一、外部 ID/去重键/回执建索引；远端人工编辑后须重读比对而非本地旧值覆盖。

---

## 3. 凭证与数据安全（替代 v0.1 §7 的「最小要求」措辞）

审计结论：v0.1 §7 的 5 条要求中，**仅第 3 条（日志脱敏）已满足**，其余为**待改造项**。

| v0.1 要求 | 真实状态 | 落地方式 |
|---|---|---|
| 1. 凭证存 OS keystore，业务库只存 `secret_ref` | **Unsupported** | 无 `flutter_secure_storage`/keystore 依赖，`lib/secrets/` 仅占位常量；真实明文落盘 `settings_provider.dart:3117-3123 → provider_rows.payload`（`business_repository.dart:426-433`），`ProviderConfig.toJson` 含 `apiKey/oauthCredentials/...`（`:6306-6657`），`docs/provider-oauth.md:20` 确认。须**新增依赖 + 平台适配 + `ProviderConfig` 改造 + 现有 `provider_rows.payload` 的增量迁移**（不得造成账号失效，v0.1 §7.1） |
| 2. 默认导出剔除凭证，含密钥备份须明确选择且加密 | **Unsupported** | `backup_scope.dart:19,21` 默认全含、`backup_content_filter.dart:18-23`、导出逐字保留（`data_sync.dart:3243-3257`、`business_settings_router.dart:295-319,577-626,877-902`）；仅存在可选「整文件」AES-256-GCM + Argon2id（`backup_encryption.dart:21-31,59`，默认关闭 `settings_provider.dart:1490`）。须新增 scrub 步骤 + 恢复兼容决策 |
| 3. 日志屏蔽 Token / 敏感 Headers | **Verified** | `lib/core/services/logging/log_redactor.dart:3-122`，已接入 `dio_http_client.dart`、`flutter_logger.dart:136`、`provider_oauth_adapter.dart:163`。best-effort，新增 secret 格式时扩展 |
| 4. 最小授权、确认写入目标与账号 | **Requires Adaptation** | 复用 `conversation_tool_permissions.dart:133-214`（`ToolPermissionMode.requestApproval/fullAccess`）+ 新建 chat-independent 审批 |
| 5. 提示词注入隔离 | **Unsupported** | `lib/features/instruction_injection/` 是用户主动注入 CRUD（`instruction_injection_provider.dart:45-50` 直接拼接进 system prompt），无 delimiter/untrusted/sanitize；须新建「外部文本一律作为待分析数据」的隔离层（对应 v0.1 测试用例 10） |

---

## 4. UX 与集成（替代 v0.1 §6 的技术假设）

产品意图不变；技术落点修正：

- **桌面**：`lib/desktop/desktop_home_page.dart:43,277-295` 是固定 4 槽 `IndexedStack`（0=Chat,1=Translate,2=Storage,3=Settings），`desktop_nav_rail.dart:27,57-102` 每项硬编码 `_CircleAction`、`:56 clamp(0,3)`。新增「收件箱」须同时改这两处 + 索引注释 + clamp + l10n tooltip。
- **移动**：`lib/features/home/pages/home_mobile_layout.dart:93-140` 无顶层目的地列表，非聊天入口靠 `side_drawer.dart:2889-2923` 图标 + `Navigator.push`（`settings_page.dart:291,359`）。新增入口走抽屉按钮或 push 路由。
- **路由**：`go_router` **不存在**；`main.dart:1210-1223,1360-1368` 为 `MaterialApp.home` + 平台切壳 + 命令式 `Navigator.push`。不要按「声明路由」设计。
- **分栏**：`AGENTS.md:10,61` 约定用 `ResponsiveHelper`（`screen_type_helper.dart:4-13` 只有 4 个静态方法）；真实 home 用 `home_page.dart:753-792` 的 `MediaQuery + AppBreakpoints.tablet + isDesktopPlatform`，`scheduled_tasks_page.dart:568` 用 `service.isDesktop`。新页遵循两者。
- **组件/主题/i18n**：`lib/shared/widgets/` 67 个（SectionCard/CustomBottomSheet/IosFormTextField/IosCheckbox/InteractiveDrawer…）；图标 `lucide_icons_flutter`（AGENTS.md:59）；**桌面禁 bottom sheet**（AGENTS.md:58）；`lib/l10n/` 7 ARB / 5 locales / 6 UI 语言，改 `app_en.arb` + `app_zh.arb`（每键带 `@key.description`）后 `translate.py sync` + `check` + `flutter gen-l10n`，提交 ARB + 状态 + 生成物。
- **CI**：`.github/workflows/pr-check.yml`（Flutter 3.47.6）跑 `dart format`（改动文件）、`flutter gen-l10n` + `git diff --exit-code -- lib/l10n`、`translate.py check`、l10n 工具单测、`dart analyze --fatal-infos lib test integration_test tool`、`flutter test`（全量）、markstream 同套。**PR 不触发 Windows/Android 构建**（`build*.yml` 仅 `workflow_dispatch`）。

---

## 5. 施工阶段与开工门槛（替代 v0.1 §8 的阶段 0 描述）

### 阶段 0（本次交付，已完成）

- 锁定 commit、核实 Android/Windows 入口、跟踪 `附件 → Provider → 模型结果`、核验 MCP tool 发现/调用/审批/认证、Drift 迁移与 Provider OAuth 落盘/备份、CI/UX 约定。
- 输出差距表与真实路径 → `universal_inbox_phase0_gap_analysis.md`。
- 按结果修正本设计 → 本文件 v0.2。
- **结论：不进入编码**（v0.1 §8「不通过则更新本设计而不是硬写代码」）。

### 阶段 1～3 的开工门槛（未满足，需需求方/环境提供）

1. **工具链**：安装 Flutter 3.47.6（与 `pr-check.yml` 一致）+ Dart SDK，`flutter pub get --enforce-lockfile`；否则无法 `dart analyze` / `flutter test` / `build_runner` / `gen-l10n` / `flutter build`，也无法产出 UI 改动所需的 Before/After 视觉证据。
2. **§10 未决项（需产品/运行决策，本版不代拍）**：
   - 首批两个真正可写连接器的实际选择与 API 限额（v0.1 §2 P0、§10）——源码无法回答，真实 MCP 无 CRUD 契约；
   - 跨设备对同一外部对象的幂等键协调机制（需运行/设备测试确定外部 API 幂等语义）；
   - 凭证明文 → OS keystore 的增量迁移是否纳入 V0/V1，及不使现有账号失效的迁移策略（v0.1 §7.1）；
   - AGPL-3.0 分发附带源码义务评估（v0.1 §9.6）。
3. **设计确认**：需求方确认本 v0.2 的技术修正后，再按 v0.1 §9.5 小步提交：数据迁移 → 事件 Schema → Provider 桥接 → Inbox UI → Connector → 执行闭环；每步带 `dart analyze` + 相关 `flutter test` + 差异说明，UI 步带 Before/After 证据。

### 已由源码回答的 v0.1 §10 项（固化，不再是未决）

- MCP 能否完全脱离聊天状态机：**否**（传输层可、高层 `McpToolService`/审批绑定 chat）→ 需解耦或走 `Client.callTool` 直调。
- Office 原生多模态：**仅 PDF 有原生输入位；DOCX 仅文本抽取；XLSX/PPTX 无解析**。
- Android `content://` 生命周期：**已用即时字节复制 + `share.json` 回执解决**，无持久授权失效风险；`PROCESS_TEXT` 为独立通道。
- 凭证落盘与备份：**明文 JSON 在 `provider_rows.payload`**，备份/导出/分享/恢复全含，仅可选整文件加密。

### 核心测试用例（v0.1 §8，保持不变）

10 条用例中，用例 5（关闭来源 App 后原件仍可访问）由现有即时字节复制天然满足；用例 6 目前仅部分满足（有 16MB 上限与 `AttachmentRequiresWorkspace`，缺统一能力协商降级层）；用例 10（提示词注入）目前**无隔离层**，须新建（§3）。其余须在实现后实测；验收指标（抽取准确率等）仍为「目标，须实测」，不在本版预设。

---

## 6. 编码纪律（沿用 v0.1 §9，补充真实约束）

1. 先源码核验 → 再修改设计 → 再编码；**不得把 v0.1/v0.2 中的拟设类型当作上游 API**（本版已把可复用项与新建项分开标注）。
2. 不引入 Docker、MinerU、Qdrant、Redis、FastAPI、独立 AI 后端或第二个模型运行时。
3. 不重新实现已有 Provider、OAuth、MCP、附件、数据库、国际化与主题组件，除非审计证明无法扩展（本版已指明扩展点）。
4. 小步提交，每步给测试与差异说明。
5. 遵守 `AGENTS.md`：desktop/mobile 分栏、复用 app widgets、Drift migration、i18n、`dart format`、`dart analyze --fatal-infos`、相关 `flutter test`；**文档改动不需要 Dart 分析/测试**。
6. AGPL-3.0：修改与分发保留版权与许可要求并评估附带源码义务。
7. **新增（本轮审计得出）**：任何 UI 改动须提供 Before/After 实际截图（同一场景/视口/主题/状态）；`Connector` 的 `search/get` 能力必须探测并对缺失能力降级；审批模型须 chat-independent；凭证改造须增量且可逆。
