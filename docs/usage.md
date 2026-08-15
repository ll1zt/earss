# Earss 使用指南（User Guide）

从零开始：安装 → 配置 → 订阅 → 连接阅读器 → 日常维护。每节都给出具体操作路径；更深的设计细节链接到对应的专项文档。

## 0. 一分钟了解

Earss 是一个**自托管 feed 阅读后端**：它抓取并存储订阅源，你用一个客户端 App（推荐 **NetNewsWire**）来阅读。管理入口是浏览器里的 Admin 控制台（默认 `http://localhost:4000/admin`）。

| 入口 | 用途 |
|------|------|
| `/admin` | **管理控制台**——订阅、健康、批量操作、翻译、指标、导出 |
| `/fever/` | Fever 协议（NetNewsWire「Fever」账户类型） |
| `/api/greader.php` | FreshRSS / Google Reader 协议（NetNewsWire「FreshRSS」账户类型） |
| `/api/*` | 自有 JSON API（Bearer token，见 [api.md](api.md)） |
| `/health` | 存活检查 |

## 1. 安装与启动

三种方式任选：

- **本地开发**：`mix setup`，然后 `iex -S mix`（默认端口 4000）——见 [development.md](development.md)
- **Docker Compose**：`cp .env.docker.example .env` → 填 `SECRET_KEY_BASE` / `ADMIN_PASSWORD` → `docker compose up -d --build`——见 [docker.md](docker.md)
- **NixOS**：声明式模块——见 [nixos.md](nixos.md)
- **裸机 Mix release + systemd**：见 [deploy.md](deploy.md)

## 2. 首次配置（凭据）

Earss 是**单操作员模式**：所有凭据来自环境变量（`earss.env` 文件或进程环境），不在数据库里。

| 变量 | 用于 | 必填？ |
|------|------|--------|
| `ADMIN_PASSWORD` | Admin 登录、JSON API 登录、GReader 账户密码 | **是**（不设则无法登录） |
| `FEVER_API_KEY` | NetNewsWire 的 Fever 账户 | 用 Fever 账户时必填 |

```bash
cp earss.env.example earss.env
# 编辑 earss.env：
#   ADMIN_PASSWORD=<强密码>
#   FEVER_API_KEY=<随机十六进制>
# 然后重启应用
```

> **首次登录自诊断**：如果没设置 `ADMIN_PASSWORD`，登录页会明确告诉你缺哪个变量（而不是只说"密码错误"）。
>
> `earss.env` 改动后需要**重启**；改了 `EARSS_*_PLUGINS` 还需要先 `mix deps.get && mix compile`（见 [development.md](development.md)）。

## 3. 订阅内容

### 3.1 普通 RSS/Atom/JSON Feed

**Admin → Subscriptions**，顶部表单粘贴 Feed URL（可带标题、分类），勾选 **Fetch now** 立即抓取，否则等轮询器（默认 5 分钟一轮）。

### 3.2 批量导入 OPML

**Admin → OPML** 粘贴 OPML XML 导入；导出用同页的 Download OPML。导入的 feed 进入轮询队列，不会立即抓取。

### 3.3 插件源（Telegram / 知乎等非 RSS 源）

**Admin → Sources**：查看已注册适配器、路由向导（填参数自动拼 `earss://` URL）、直接订阅 `earss://…` URL。插件是编译期依赖，在 `earss.env` 配置：

```bash
EARSS_SOURCE_PLUGINS=github:ll1zt/earss_source_telegram@main
mix deps.get && mix compile   # 然后重启
```

细节见 [sources.md](sources.md)。

### 3.4 订阅列表管理

列表支持：

- **筛选**：关键词（标题/URL）、分类、状态（all/visible/hidden/error/disabled/due）
- **排序**：标题 / 未读数 / 下次抓取 / 最新
- **分页**：50 条/页，翻页保留筛选条件
- **批量操作**（勾选行 + 批量栏，上限 50）：Refresh / Hide / Unhide / Move to category / Unsubscribe（危险操作有确认）
- 行内：Edit（详情页）/ Refresh / Unsubscribe

> 术语：**Feed** 是共享抓取对象，**Subscription** 是「你订阅了它」这个事实（含你的标题、分类、隐藏、自定义间隔）。隐藏（Hide）只影响你的视图与调度聚合，不停止抓取；停用抓取用 Feeds 页的 Disable。

## 4. 连接阅读器（NetNewsWire）

两种账户类型都已实测可用，任选其一（或都加）：

### 4.1 FreshRSS / GReader（推荐）

| 字段 | 值 |
|------|-----|
| 账户类型 | **FreshRSS** |
| URL | `http://HOST:4000/api/greader.php` |
| 用户名 | 随意（如 `earss`） |
| 密码 | `ADMIN_PASSWORD` |

细节：[greader.md](greader.md)

### 4.2 Fever

| 字段 | 值 |
|------|-----|
| 账户类型 | **Fever** |
| URL | `http://HOST:4000/fever/` |
| 用户名 | 随意 |
| 密码 | `FEVER_API_KEY`（注意：不是 ADMIN_PASSWORD） |

细节：[fever.md](fever.md)

> Dashboard 底部的 NetNewsWire 卡片列出了两个 URL，带一键复制按钮。
> 阅读状态（已读/星标）在 Admin 的未读统计与 NNW 之间按同一套规则计算，见 [greader.md](greader.md) 的排障节。

## 5. 日常维护

### 5.1 Dashboard（`/admin`）

- 统计行：订阅数、未读数、分类数、问题 feed、到期 feed（可点击跳转筛选视图）
- **Recent entries**：全站最新 12 条（标题直链原文 + 翻译状态徽章），不用开阅读器就能确认抓取/翻译效果
- **Fetch health**：内存指标（抓取次数、失败数、平均延迟、最近失败，自启动起）
- **Problem / Due feeds**：快捷 Refresh / Re-enable

### 5.2 Feeds 健康页（`/admin/feeds`）

- 状态筛选：all / active / disabled / error / due；排序：标题 / 下次抓取 / 错误数 / 上次抓取
- 批量：Refresh（强制重抓）/ **Re-enable**（清除熔断，恢复调度）/ **Disable**（停止调度）
- 单行 Refresh 是 `force: true`——可以修复"抓到了但解析错"的 feed

> **熔断机制**：连续 5 次抓取失败后 feed 会被禁用（`disabled` 徽章），需要手动 Re-enable。

### 5.3 到期与调度

轮询器每 5 分钟（可配 `POLLER_INTERVAL_MS`）抓取到期 feed。单个 feed 的间隔自适应：有新内容→回到默认间隔，连续无内容→逐渐拉长，出错→指数退避。间隔的最小值取「feed 基线」与「所有未隐藏订阅的自定义间隔」的最小值（决策 D1，见 [data_model.md](data_model.md)）。

### 5.4 数据保留（`/admin/system`）

三档清理（先 **Dry run** 看影响，再 **Run cleanup**）：

| 档 | 内容 | 默认窗口 |
|----|------|----------|
| A | 已读且未星标的阅读状态 | 90 天 |
| B | 无状态且可回收的条目 | 180 天 |
| C | 零订阅的 feed | 30 天 |

也可配成每日自动运行（`RETENTION_POLLER_*`）。

### 5.5 指标（`/admin/metrics`）

内存聚合（不落盘，重启/Reset 清零），页面每 30 秒自动刷新：

- **Feed fetch**：各结果计数（success / not modified / http error / parse error / adapter error）+ 平均/最小/最大延迟
- **Poller cycle / Ingest-hook translation / Pending-worker retry**：周期计数与延迟
- **Recent fetch failures**：最近失败列表（feed 链接 + 原因 + 时间）
- Reset 按钮清空计数（uptime 保留）

### 5.6 导出与备份

- **Admin → Export**：星标或全量条目导出 Markdown / JSON；OPML 导出
- **数据库备份**：`pg_dump`（详见 [backup.md](backup.md)）——指标、会话等都不在数据库里，**备份 = 数据库 dump + 媒体目录（如有）**

## 6. 翻译（可选功能）

把订阅内容自动翻译成指定语言（OpenAI 兼容接口；新条目**翻译完成前对阅读器隐藏**，避免客户端缓存到半成品）。

### 6.1 安装翻译插件

```bash
# earss.env
EARSS_TRANSLATE_PLUGINS=path:../earss_translate_openai
EARSS_TRANSLATE_OPENAI_API_KEY=sk-...
EARSS_TRANSLATE_OPENAI_MODEL=gpt-4o-mini
# mix deps.get && mix compile，重启
```

验证：**Admin → Translate** 顶部应显示插件信息（否则有"No translation plugin loaded"提示）。

### 6.2 启用（按 feed）

**Admin → Subscriptions → 某个订阅的详情页 → "Feed translation" 表单**，填：

- `translate_to`：目标语言（如 `zh`）
- `translate_from`：**留空**=自动检测（推荐）
- `original text layout`：是否附带原文（off / inline / section / interleaved）

也可在 **Categories** 页对整分类批量套用同一目标语言。启用后**新抓取的条目**开始翻译；存量条目保持原文。

### 6.3 跟踪与处置

**Admin → Translate**：

- **Overall progress**：全局 done / pending / paused / errors，按语言显示进度条
- 每 feed 一行状态：处理中 / 已暂停 / 已跟上
- 批量操作：**Re-translate paused**（重试失败条目）/ **Publish originals**（放弃翻译，直接发布原文）

> **pending / paused 语义**：pending = 翻译中（对阅读器隐藏）；连续失败 5 次后进入 paused（仍隐藏，等你在 Admin 决定重试还是发原文）。停用翻译时 pending 会自动清空（原文重新可见）。

### 6.4 阅读

客户端**无需配置**：翻译存在时 GReader/Fever 直接返回译文。原文逃生舱：GReader 请求加 `?original=1`。细节与缓存行为见 [translate.md](translate.md)。

## 7. 故障排查

| 现象 | 检查 |
|------|------|
| 登录提示 "not configured" | `earss.env` 缺 `ADMIN_PASSWORD`，设置后重启 |
| 登录提示 "Invalid password" | 密码与 `ADMIN_PASSWORD` 不符（改过 env 要重启） |
| feed 徽章 `disabled` | 连续 5 次抓取失败已熔断；Feeds 页 Re-enable，或看 `last_error` 判断原因 |
| feed 徽章 `error` | 有错误计数；详情页看 `last_error`；Refresh（force）重试 |
| NNW 看不到新文章 | ①账户类型/URL 是否与第 4 节一致 ②该 feed 是否启用了翻译且条目还在 pending（Admin → Translate 查状态）③NNW 账户用 `FEVER_API_KEY`（Fever）还是 `ADMIN_PASSWORD`（FreshRSS） |
| 翻译一直 pending | 无插件/无目标语言会清空；有插件则查 paused 数，批量 retry 或 publish |
| 插件没出现在 Sources/Translate | `EARSS_*_PLUGINS` 配好后是否执行了 `mix deps.get && mix compile` 并重启；显式模块可用 `EARSS_SOURCE_ADAPTERS` / `EARSS_TRANSLATE_ADAPTERS` |
| 端口占用 | 设 `PORT`（如 `PORT=4100`） |
| 抓取慢/超时 | 默认每 feed 60 秒超时（`POLLER_TIMEOUT_MS`，慢插件可调大）；单 feed 手动 Refresh 无此限制 |
| 改了 earss.env 没生效 | 运行时键需**重启**；插件键需 `mix deps.get && mix compile` 再重启 |
| 指标页数字对不上 | 指标是内存聚合（自上次启动/Reset 起），重启即清零 |

## 8. 术语速查

| 词 | 含义 |
|----|------|
| feed | 全局共享的抓取对象（一个 URL/源一条记录） |
| subscription | 你对该 feed 的订阅（标题/分类/隐藏/间隔） |
| entry | 一篇文章（全局存储一次，多订阅共享） |
| unread | 懒状态：无 `entry_states` 行或 `is_read=false` |
| due | `next_fetch_at` 已到，等待轮询 |
| disabled | 熔断（5 次连错）或手动 Disable |
| pending / paused | 翻译状态：处理中 / 失败待处置（都对阅读器隐藏） |
| hidden | 订阅隐藏（不计入调度聚合，但仍抓取） |
| force refresh | 忽略条件请求（etag/304）直接抓取 |
| D1 interval | 生效间隔 = min(feed 基线, 所有未隐藏订阅的自定义间隔)，再钳制到 min/max |

## 9. 文档索引

| 想做什么 | 看这里 |
|----------|--------|
| 日常使用 | 本文（`docs/usage.md`） |
| Admin 控制台全功能 | [admin.md](admin.md) |
| 连接 NetNewsWire | [greader.md](greader.md) · [fever.md](fever.md) |
| 自有 JSON API | [api.md](api.md) + [openapi.yaml](openapi.yaml) |
| 翻译配置与语义 | [translate.md](translate.md) |
| 插件源（earss://） | [sources.md](sources.md) |
| 部署（release/systemd） | [deploy.md](deploy.md) |
| Docker | [docker.md](docker.md) |
| NixOS | [nixos.md](nixos.md) |
| 安全（公网暴露前必读） | [security.md](security.md) |
| 备份恢复 | [backup.md](backup.md) |
| 开发/测试 | [development.md](development.md) |
| 架构与数据模型 | [architecture.md](architecture.md) · [data_model.md](data_model.md) |
