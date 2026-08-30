# MCP 服务设计方案（Earss）

> 状态：**4 项决策已拍板，方案待确认后进入实施**。本文只做设计，不改代码。
> 目标：给 Earss 加一套面向 agent 的 MCP 服务，覆盖三条需求——
> ① agent 能做用户能做的所有操作；② 类爬虫的内容采集入库，并复用翻译/TTS 管线；
> ③ 友好的内容查询。

---

## 0. 需求确认（我对三条需求的理解，如有偏差请纠正）

### 需求 1 — agent 具备用户的全部能力
「用户能做的」= Admin 控制台 + JSON API 的并集。我把它们映射为三类：

| 类 | 范围 | 例子 |
|---|---|---|
| 订阅面 | 分类 CRUD、订阅/退订/隐藏/改标题/改间隔、OPML 导入导出 | `subscribe`、`import_opml` |
| 阅读面 | 时间线、标记已读/未读/加星/批量已读、导出 | `list_entries`、`mark_read` |
| 运维面 | 强制刷新、翻译开关与批处理、TTS 队列管理、系统状态、指标 | `refresh_feed`、`translate` |

**已定：全暴露 + 标注。** 「破坏性操作」（退订、删除 TTS 请求、删除分类）
全部暴露，用 MCP **tool annotation**（`destructive: true`）标注，由客户端提示用户确认。
服务端**另外**提供 `MCP_READ_ONLY=true` 开关供只读场景。
这样才真正满足「agent 能做用户能做的一切」。

> 注：MCP 规范要求客户端把 tool annotation 视为不可信（除非来自可信 server）——
> 该警告针对第三方 server；Earss 是自托管的一方可信 server，此路径下注解可信。

### 需求 2 — 类爬虫采集 + 复用现有管线
这一条我拆成两个**本质不同**的子需求，因为它们的技术路径完全不同：

**2a. 抓取 RSS 源时间范围外的内容（backfill）**
RSS 天生只给最近 N 条。要拿历史，只能靠：分页/归档页、站点 API、
或插件已有的游标机制（`adapter_cursor`）。
→ 这条路**必须落在 source 插件里**，核心不该知道「知乎怎么翻页」。

**2b. 把抓到的任意内容入库**
比如 agent 用 WebFetch 拿到一篇文章，想塞进 Earss 以便后续翻译/收听。

**这里有一个硬约束必须先说清楚**（我读了代码确认）：
`entries` 表 `validate_required([:link, :guid, :feed_id])`——
**没有 feed 就不能有 entry**。不存在「自由浮动的条目」。
所以「任意内容入库」必须先回答「它属于哪个 feed」。

**方案（已定：动态多容器）**：引入**虚拟 feed**（virtual feed）——
`feed_type: "manual"` 的容器，代表「agent 采集的内容」。
按 `container` 参数**按需建多个**（`agent/research-2026Q3`、`agent/competitor-watch`…），
每个容器可独立设置翻译/TTS。
这既满足需求，又不破坏「一次抓取、多读者」的既有模型，
且让这些条目自动获得订阅/已读/加星/导出/翻译/TTS 的全部能力。

**管线复用**：翻译和 TTS 都已有成熟的「DB 侧编排 + 插件侧算法」契约
（`Earss.Source.Enricher` / `Earss.TTS.Provider`）。采集入库后，
只要让条目走已有的 pending 标记逻辑，翻译/TTS 就是**自动**的，不需要新管线。

### 需求 3 — 友好的内容查询
「友好」我理解为三层，缺一层 agent 就不好用：

1. **能查到** — 时间线（按 feed/分类/已读/加星/时间范围过滤）
2. **能找着** — 关键词搜索。**这是当前架构的空白**：我 grep 过全库，
   `lib/` 里**没有任何** `ilike` / `tsvector` / 全文检索代码。
3. **能看懂** — 返回内容要包含状态（已读/加星）、翻译状态、TTS 状态、
   所属订阅，并且**正文要能控制长度**（否则一次塞 20 篇长文会炸上下文）

---

## 1. 技术选型结论

### 1.1 协议版本：必须实现 2026-07-28（这是硬结论，不是偏好）

我查了官方规范，有一个**颠覆认知**的变化，它直接影响选型：

> MCP **2026-07-28 与之前所有版本在 wire 上不兼容**。

具体变更（均来自 official spec）：

- **取消了 `initialize` 握手**。不再有 session 协商。
  每个请求通过 `_meta` 自带协议版本，服务端逐请求独立接受或拒绝。
- 新增 **`server/discover`**，服务端 **MUST** 实现。
- **移除 GET 流端点**、**移除协议级 session**（`Mcp-Session-Id` 不再使用）。
- Streamable HTTP 新增强制头：`MCP-Protocol-Version`、`Mcp-Method`、
  以及 `tools/call` 时的 `Mcp-Name`；并要求**头-体一致性校验**
  （不匹配返回 `400` + JSON-RPC `-32020 HeaderMismatch`）。
- 服务端到客户端的交互改为 **MRTR**（多轮请求，返回 `InputRequiredResult`），
  不再在 SSE 上反向发请求。

**含义**：如果我按 2025-06-18 的旧知识来设计（有 `initialize`、有 session），
会做出一个**已经过时且无法与新版客户端互通**的服务。

### 1.2 用 `ex_mcp`，不自己写协议层

| 候选 | 结论 |
|---|---|
| **`ex_mcp` ~> 1.1** | ✅ **选它**。1.1.1 发布于 2026-08-27（昨天），原生支持 2026-07-28， |
| | 并通过官方一致性套件：**387/387 client + 149/149 server**（2026-07-28 全量）。 |
| | 提供 `ExMCP.HttpPlug`（Plug 原生集成，与本项目 Bandit+Plug 契合）、 |
| | DSL、MRTR、subscription、OAuth 2.1。3500+ 测试，MIT。 |
| **`anubis_mcp` ~> 2.0** | 2.0.0 发布于 2026-08-07。定位是 **Phoenix 集成**， |
| | 本项目**没有 Phoenix**，强绑定 Phoenix 会带来不必要的耦合。 |
| **`hermes_mcp`** | 停更于 2025-08，其 API 面向旧版协议，不选。 |
| 自己实现 | ❌ 强烈不建议。2026-07-28 的 header 校验、版本协商、MRTR、 |
| | SSE 语义细节很多，自研等于用项目预算重做一致性认证。 |

**但有一个重要提醒**：`ex_mcp` 1.0.0 之后默认 `:prefer_modern`，
且 CHANGELOG 明确记录了它自身修过的多个安全洞
（DNS rebinding、TLS 选项被忽略、JWT 不过期检查等）。
用库≠免检，我们要做的是**正确配置**它（尤其是 Origin 校验），
而不是重新实现它。

### 1.3 传输方式：HTTP（非 stdio）

Earss 是常驻服务（Bandit + 后台 poller），MCP 端点挂在现有 HTTP 端口上：
`POST /mcp`。理由：

- 与现有 `/api`、`/fever/`、`/admin` 同一进程、同一端口、同一 TLS 终止
- 复用现有反向代理（`tailscale serve` / nginx）与鉴权链路
- stdio 需要 agent 在 Earss 机器上起子进程，不适合自托管常驻服务

---

## 2. 架构设计

### 2.1 分层：MCP 是**第四个协议适配器**，不是新业务层

这是本方案最重要的结构决策。现有架构已经有三个协议适配器：

```
Earss.Reader (facade)  Earss.Feeds (facade)  Earss.TTS / Enrichment
        │                      │                      │
   ┌────┴─────┐          ┌─────┴─────┐                │
   │          │          │           │                │
GReader     Fever    Admin UI    JSON API          Podcast
```

MCP 应当**与它们平级**，复用同一批 facade：

```
lib/earss/mcp/
  router.ex          # Plug，挂 /mcp（转发到 ExMCP.HttpPlug）
  handler.ex         # ExMCP.Server.Handler + DSL：工具注册表
  tools/
    subscriptions.ex # 需求 1：订阅面
    reading.ex       # 需求 1+3：阅读面与查询
    ingest.ex        # 需求 2：采集入库
    pipeline.ex      # 需求 2：翻译 / TTS 触发
    system.ex        # 需求 1+3：运维与状态
  views.ex           # MCP 专用渲染（尺寸控制、状态扁平化）
  auth.ex            # 鉴权
```

**铁律**（写进 `docs/development.md`）：
`Earss.MCP.*` **只能调 facade**（`Earss.Reader` / `Earss.Feeds` / `Earss.TTS` /
`Earss.Enrichment`），**不得直接碰 `Repo` 或 schema**。
理由同既有规矩：一个查询逻辑只应存在一个地方。
现有 `Earss.API.JSON` 已经是这个模式，MCP 照抄即可。

### 2.2 数据流

```
agent ──POST /mcp──▶ ExMCP.HttpPlug ──▶ Earss.MCP.Handler
                                              │ (DSL dispatch)
        ┌─────────────────────────────────────┼──────────────────────┐
        ▼                                     ▼                      ▼
  Tools.Subscriptions                Tools.Ingest            Tools.Reading
        │                                     │                      │
        │                          Feeds.ensure_feed/1         Reader.list_entries/1
        │                          Feeds.upsert_entry/2        Reader.mark_read/1
        │                                     │                      │
        └─────────────────────────────────────┴──────────────────────┘
                                              │
                                      ┌───────┴────────┐
                                      ▼                ▼
                              Enrichment（翻译）   TTS（收听）
                              —— 已有管线，自动生效 ——
```

---

## 3. 工具集设计

命名用 `snake_case` + 领域前缀（`feed_*` / `entry_*` / `tts_*`）。
规范允许 1–128 字符，含 `.` `_` `-`；前缀能降低多 server 聚合时的撞名风险。

> **实现状态**：✅ = 已实现；🚧 = 设计中（未实现）。当前里程碑交付的是
> **查询 + 采集 + 搜索 + backfill**；订阅/分类/OPML 管理面未实现。

### 3.1 订阅面（需求 1）

| 工具 | 状态 | 对应现有 API | 说明 |
|---|---|---|---|
| `feed_list` | ✅ | `GET /api/subscriptions` | 含未读数、分类、健康状态 |
| `feed_subscribe` | 🚧 | `POST /api/subscriptions` | 支持 `http(s)` 与 `earss://` |
| `feed_unsubscribe` | 🚧 | `DELETE /api/subscriptions/:id` | ⚠️ destructive |
| `feed_update` | 🚧 | `PATCH /api/subscriptions/:id` | 标题/间隔/隐藏/分类 |
| `feed_refresh` | 🚧 | `POST /api/feeds/:id/refresh` | 立即抓取 |
| `category_*` | 🚧 | `/api/categories` | 删除 ⚠️ destructive |
| `opml_export` / `opml_import` | 🚧 | `/api/opml/*` | 导入 ⚠️（会建订阅） |

### 3.2 阅读面（需求 1）

| 工具 | 状态 | 说明 |
|---|---|---|
| `entry_mark_read` / `entry_mark_unread` / `entry_star` / `entry_unstar` | ✅ | 单条 |
| `entry_mark_read_batch` | 🚧 | 按 ids / feed_id / category_id 批量 |

### 3.3 查询面（需求 3）—— 本方案的重点

| 工具 | 状态 | 说明 |
|---|---|---|
| `entry_list` | ✅ | 时间线：feed/分类/已读/加星 + 分页 |
| `entry_search` | ✅ | **新增能力**，见 §4 |
| `entry_get` | ✅ | 单条完整正文 |
| `feed_stats` | 🚧 | 各订阅条目数/未读/错误数/下次抓取 |
| `system_status` | 🚧 | 健康、poller、retention、指标摘要 |
| `translation_status` | 🚧 | 哪些条目 pending/paused，错误数 |
| `tts_list` | 🚧 | TTS 队列状态 |

**`entry_list` / `entry_search` 的响应必须做尺寸控制**（这是「友好」的关键）：

```json
{
  "entries": [{
    "id": 12345,
    "title": "...",
    "feed_title": "...",
    "published_at": "...",
    "is_read": false, "is_starred": true,
    "translation": {"target": "zh", "state": "ready"},
    "tts": {"state": "none"},
    "excerpt": "前 500 字…"
  }],
  "next_cursor": "eyJvIjoxMDB9",
  "truncated": true
}
```

设计要点：
- **默认给 excerpt 不给全文**。agent 要看全文再调 `entry_get`。
  理由：20 篇 × 5000 字会直接撑爆上下文窗口，这是 agent 集成最常见的失败模式。
- **状态内联**（已读/加星/翻译/TTS），省掉 agent 的多次往返。
- **cursor 分页**而非 offset：条目按发布时间倒序，期间有新条目插入时
  offset 会漏/重复，cursor 不会。

### 3.4 采集入库（需求 2）

**`ingest_items`** ✅ —— 把一批内容存进一个容器 feed：

```
参数:
  container: 字符串（容器名/URL，如 "agent/research-2026Q3"）
             → 内部映射为一个 virtual feed（feed_type: "manual"）
  title / link: 可选，容器不存在时用于创建
  items: [{
    title, link, guid?, author?, summary?, content?,
    published_at?      # 缺失时用 now
  }]
  pipeline: {
    translate_to?: "zh",     # 触发翻译（复用 Enrichment）
    tts?: true,              # 触发 TTS（复用 TTS.record_request）
    refresh?: false          # 是否让 poller 抓这个容器
  }
返回:
  {feed_id, created: n, updated: m, skipped: k,
   translation: {requested: n}, tts: {requested: n}}
```

**为什么用容器 feed 而不是「无 feed 条目」**：
- 硬约束：`entries.feed_id` 非空（已验证 `validate_required([:link, :guid, :feed_id])`）
- 容器 feed 让这批内容**自动获得**订阅、已读/加星、导出、
  翻译、TTS、retention 的全部能力——这正是「灵活利用现有管线」的诉求
- 不破坏既有模型（仍然是 feeds → entries）

**动态多容器（已定）**：`container` 参数即容器标识，不存在时自动创建。
每个容器是独立 feed，因此：
```
agent/research-2026Q3  → translate_to: zh, tts: on
agent/competitor-watch → translate_to: nil（不翻译）
agent/inbox            → 默认
```
agent 可按主题分类管理，且各容器的翻译/TTS 互不干扰。

**容器命名规则**（已实现）：`link` 存 `earss://agent/<container>`，
`feed_type: "manual"`、`adapter_id: "native"`（已注册默认值）。

> 实现时用 `adapter_id: "native"` 而非最初设想的 `"manual"`：
> `Resolver.adapter_module/1` 对未知 id 会回落 native，所以自造一个 id
> 最终也解析到 native——但走的是查找失败路径，是绕远路得到同一个结果。
> 显式用 native 更诚实。容器**永不抓取**由两道防线保证：
> `FeedScheduler.list_due_feeds/2` 排除 `feed_type = "manual"`，
> `Feeds.Fetcher` 对 manual feed 的显式 refresh 直接拒绝。

**去重与幂等**：`upsert_entry` 已按 `(feed_id, guid)` upsert，
且 `content_hash` 未变则跳过。**guid 缺省时回落为 link**（已验证逻辑）。
所以重复采集同一 URL 是安全的。

**翻译/TTS 如何自动生效**（这是「复用管线」的落点）：
1. `ingest_items` 写入条目
2. 若 `translate_to` 给定 → 设置该 feed 的 `translate_to`，
   并调用已有的 `Enrichment.mark_pending/2` 打 pending 标记
   → 既有 `PendingWorker` 会自动消费 → 无需新逻辑
3. 若 `tts` 为真 → 对每条调 `TTS.record_request/1`（已幂等）
   → 既有 `TTS.Worker` 自动合成

**关键**：这两条我都**不新写编排逻辑**，只做「打标记/建请求」。

### 3.5 Backfill（需求 2a）—— 明确划入插件职责

`feed_backfill(feed_id, opts)` ✅ **只做编排**：
1. 校验 feed 的 `adapter_id`
2. 若 adapter 实现了可选的 `backfill/2` 回调 → 调它
3. 拿回 entries 后走**与正常抓取完全相同的入库路径**（`Feeds.ingest_payload/3`）
4. 翻译钩子由那条入库路径自动触发（不重复实现）

**核心不做「怎么翻页」**。理由与现有 `Earss.Source.Adapter` 契约一致：
站点知识属于插件。`packages/earss_source` 的
`Earss.Source.Adapter` 已加**可选回调**（`@optional_callbacks backfill: 2`）：

```elixir
@callback backfill(feed :: struct() | map(), opts :: keyword()) ::
            {:ok, fetch_ok()} | {:error, term()}
```

可选 + `function_exported?/3` 探测 → 未实现的插件行为不变（`api_version` 保持 1，
这是**向后兼容**的增量，与我之前 review 时看到的契约演进方式一致）。

---

## 4. 需要新增的能力（当前架构的空白）

### 4.1 全文搜索：PGroonga（已定稿）

我确认过：`lib/` 下**没有任何搜索实现**（无 `ilike`/`tsvector`/FTS）。这是需求 3 的硬缺口。

你选了「用扩展，支持英/中/日」。我查证后的结论：

**选 `pgroonga`，不用 `zhparser`/`pg_jieba`。**

| 候选 | nixpkgs 可得性 | 结论 |
|---|---|---|
| **`postgresql18Packages.pgroonga`** (4.0.5) | ✅ 在 nixpkgs | **选它** |
| `zhparser` | ❌ 不在 nixpkgs | 需自行打包，排除 |
| `pg_jieba` | ❌ 不在 nixpkgs | 需自行打包，排除 |
| `postgresqlPackages.pg_bigm` (1.2) | ✅ | 仅 bigram，不如 PGroonga 全面 |
| `postgresqlPackages.tsja` (0.5.0) | ✅ | 仅日语，不满足中日英 |

**为什么 PGroonga 正好满足「英中日」**：它的默认分词器 `TokenBigram`
**对非 ASCII 字符用 bigram、对 ASCII 字符用空格分词**（官方 reference）：

> Tokenizer: `TokenBigram` — It's a bigram based tokenizer. It combines bigram
> tokenization and white space based tokenization. It uses bigram tokenization
> for non ASCII characters and white space based tokenization for ASCII characters.

即：中文/日文按 bigram 切，英文按空格切，**同一列混排多语言无需任何配置**。
官方明确定位就是解决 PG 内置 FTS 不支持 CJK 的问题。
默认 `NormalizerAuto`（UTF-8 走 NFKC）+ 支持相关度排序。

**迁移**（`priv/repo/migrations/`）：
```sql
CREATE EXTENSION IF NOT EXISTS pgroonga;

CREATE INDEX entries_search_idx ON entries
  USING pgroonga (title, content);
```
不加 `tokenizer=` 选项，用默认 `TokenBigram`。
（官方建议：除非确有需求，不要在 alphabetic 语言上开 `TokenNgram(unify_...)` 部分匹配，噪声大。）

**查询**（Ecto 里走 `fragment`）：
```sql
SELECT *, pgroonga_score(tableoid, ctid) AS score
FROM entries
WHERE title &@~ $1 OR content &@~ $1
ORDER BY score DESC;
```

**部署改动（NixOS）** —— 照搬现有 `citext` 的做法：
```nix
services.postgresql.extensions = [ pkgs.postgresql18Packages.pgroonga ];
# 再加一个 earss-postgres-setup 风格的 oneshot unit 执行 CREATE EXTENSION
```
现有 `nix/module.nix` 已有 `earss-postgres-setup`（为 citext 建的，含
`after postgresql-setup.service` 的时序处理），加一个 `pgroonga` 分支即可。

**降级路径**：扩展不可用时（非 NixOS 部署、Docker、CI）
`entry_search` 自动降级为 `ILIKE`，并在响应里标注 `"search_mode": "fallback"`。
理由：搜索是 agent 的核心诉求，不能因为扩展缺失就让工具不可用。
**这条降级必须实现**，否则 CI（无 pgroonga）跑不了测试。

### 4.2 其余新增项

| 项 | 说明 | 成本 |
|---|---|---|
| `feed_type: "manual"` | Feed schema 的 `@feed_types` 白名单加一个值（纯代码，无迁移） | 小 |
| `Earss.MCP.Search` | 查询模块（PGroonga fragment + ILIKE 降级） | 中 |
| `Earss.MCP.Views` | MCP 专用渲染（excerpt/状态扁平化） | 小 |
| `Earss.MCP.Auth` | 见 §5.1 | 小 |
| PGroonga 迁移 | `CREATE EXTENSION` + `USING pgroonga` 索引 | 小 |

**注意（迁移纪律）**：按 `Ecto Iron Laws` 第 10 条，迁移必须自包含、
不引用运行时 schema。PGroonga 索引建在 `entries(title, content)` 上，
与运行时 schema 解耦，符合现有 20 个迁移的风格。

---

## 5. 安全设计（重点，MCP 是新的攻击面）

MCP 给了 agent 「用户的全部能力」，所以它**继承并放大**了现有所有风险。
以下每一项都对应一个具体威胁：

### 5.1 鉴权（已定：独立 `MCP_API_KEY`）
- 新增 `MCP_API_KEY`（`earss.env`），**不复用 `ADMIN_PASSWORD`**。
  理由：MCP 端点会长期配置在各种 agent 客户端里，
  独立密钥可单独轮换/吊销而不影响 Admin UI 与 Fever。
- `Authorization: Bearer <key>`，用 `Plug.Crypto.secure_compare` 常量时间比较
  （与 `Earss.OperatorAuth` 现有一致）。
- **默认关闭**：`MCP_ENABLED=false`，与现有 `:api` / `:poller` 的 `enabled` 风格一致。
- 另有 `MCP_READ_ONLY=true`（可选只读模式）。

```bash
# earss.env
MCP_ENABLED=false
MCP_API_KEY=<random hex>
# MCP_READ_ONLY=false
```

### 5.2 SSRF —— 这是最需要警惕的一条
我上一轮 review 刚修了一个 SSRF 洞（首次请求 URL 未纳入 blocklist）。
MCP 的 `feed_subscribe` 接受任意 URL，**是同一个攻击面的新入口**：

- **必须**让所有 MCP 触发的出站请求经过 `Earss.Feeds.HTTP`，
  从而自动获得刚修的 `safe_initial_target?/1` 保护
- **绝不能**为 MCP 单独开一条绕过 blocklist 的抓取路径
- `HTTP_ALLOW_BLOCKED_TARGETS` 一旦开启，MCP 也能打内网——
  这点必须写进 `docs/mcp.md`

### 5.3 采集入库的滥用面
- 条目数上限（如单次 100，容器总量可配）
- 单条内容大小上限（建议对齐 HTTP 的 `max_body_bytes` 思路）
- 容器 feed 数量上限，防止 agent 无限建 feed
- `container` 名称做白名单校验（防路径穿越 / 超长 / 控制字符）
- 内容仍走 `Earss.Feeds.HTMLSanitize`（**自动获得**，因为 `upsert_entry` 内部就调了）

> 注意：`upsert_entry/2` 会**无条件** sanitize，所以采集的 HTML 会被清洗。
> 若 agent 想保留富文本结构，需知悉 sanitize 是 deny-list 式（见 `HTMLSanitize` 文档）。

### 5.4 Origin 校验（DNS rebinding）
MCP over HTTP 的著名攻击：恶意网页让浏览器访问 `http://localhost:4000/mcp`。
- `ExMCP.HttpPlug` 有 `:allowed_hosts` 与 Origin 校验，**必须显式配置**
  （`ex_mcp` 的 CHANGELOG 记录了它曾默认允许空 Origin 的漏洞）
- 只监听 tailnet / localhost，不裸奔公网

### 5.5 破坏性操作（已定：全暴露 + 标注）
用 tool annotation 标注 `destructive: true`，把确认权交给客户端。
服务端**额外**提供 `MCP_READ_ONLY=true`，供只想让 agent 读的场景。

被标注为 destructive 的工具：`feed_unsubscribe`、`category_delete`、
`tts_delete`、`opml_import`（会建订阅）。

### 5.6 审计
每次工具调用记日志（工具名 + 参数摘要，**不记正文**）。
理由：正文可能很长且敏感；工具名+参数足以复盘 agent 行为。

---

## 6. 实施计划（M0–M4 全部完成）

| 阶段 | 内容 | 状态 |
|---|---|---|
| **M0** | 协议骨架：`ex_mcp` 依赖、`/mcp` 挂载、`MCP_API_KEY` 鉴权、`ping` | ✅ |
| **M1** | 读与查询：`entry_list`/`entry_get`/`feed_list`/已读·加星 | ✅ |
| **M2** | 采集入库：`ingest_items` + 容器 feed + 翻译/TTS 触发 | ✅ |
| **M3** | 搜索（PGroonga + ILIKE 降级）+ `feed_backfill` 插件回调 | ✅ |
| **M4** | NixOS 模块：`database.searchExtensions`（PGroonga）| ✅ |

**每个阶段结束时**：`mix format --check-formatted` + `mix test` 全绿（当前 507 测试）。
MCP 工具按现有契约测试风格补测试（`test/earss/mcp/`）。

### 验收标准（当前全部通过）
- [x] `mix format --check-formatted` 无 diff
- [x] `mix compile --force --warnings-as-errors` 干净
- [x] `mix test` 全绿且无新警告（507）
- [x] `MCP_ENABLED=false` 时 `/mcp` 返回 404（默认安全）
- [x] 无 `MCP_API_KEY` → 500 `mcp_not_configured`；错误 key → 401
- [x] 真实 MCP 客户端完成 `server/discover` → `tools/list` → `tools/call`
- [x] `entry_list` 默认返回 excerpt 而非全文
- [x] 容器 feed 永不被 poll（回归测试 `feed_scheduler_test`）
- [x] 采集内容走 `HTMLSanitize`（回归测试 `ingest_test`）

### 交付后的注意事项
- 当前 `MCP_API_KEY=changeme`（earss.env，已 gitignore）——**上线前必须轮换**
- 未启用 PGroonga 的部署，`entry_search` 自动 ILIKE 降级并标注 `search_mode`
- `nix flake check` 含 `module-with-search`，验证 PGroonga 分支可求值

---

## 7. 已拍板的 4 个决策

| # | 决策 | 结论 | 影响 |
|---|---|---|---|
| Q1 | 密钥 | **独立 `MCP_API_KEY`** | 可单独轮换/吊销，不影响 Admin 与 Fever |
| Q2 | 搜索 | **用扩展，支持英/中/日** | PGroonga，见 §4.1 |
| Q3 | 容器 | **动态多容器** | `container` 参数按需建 feed |
| Q4 | 破坏性 | **全暴露 + `destructive` 标注** | 另提供 `MCP_READ_ONLY` 开关 |

---

## 8. 我明确建议**不做**的事

- **不自己写 MCP 协议层** —— 2026-07-28 的 header 校验/版本协商/MRTR 细节太多，
  `ex_mcp` 已通过官方一致性认证
- **不做 MCP Resources / Prompts** —— 你的三条需求都是「操作 + 查询」，
  Tools 已足够；加了反而扩大攻击面与维护面
- **不为 MCP 单独建抓取通道** —— 必须复用 `Earss.Feeds.HTTP`，否则 SSRF 保护失效
- **不把 backfill 的站点逻辑写进核心** —— 属于插件，与现有契约一致
- **不在 tools/call 响应里返回全文列表** —— 一律 excerpt + `entry_get` 单独取
