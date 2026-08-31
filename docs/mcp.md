# MCP server（AI agents）

Earss exposes a [Model Context Protocol](https://modelcontextprotocol.io)
endpoint at `POST /mcp` so an AI agent can operate the reader the way the
operator does: browse, read, mark read/starred, collect new content, and
queue it for translation or TTS.

The server implements **MCP 2026-07-28**（`server/discover`，逐请求 `_meta`
版本协商，无 `initialize` 握手），同时向后兼容旧版客户端（`ex_mcp` 的
`:prefer_modern` 模式）。传输是 **Streamable HTTP** —— 挂载在现有 HTTP
端口上，与 `/api`、`/admin` 共享同一 TLS 与反向代理。

## 启用

```bash
# earss.env
MCP_ENABLED=true
MCP_API_KEY=<openssl rand -hex 32>
# 可选：只读模式（隐藏并拒绝所有写工具）
# MCP_READ_ONLY=true
```

**安全**：

- `MCP_ENABLED=false`（默认）时 `/mcp` 返回 404，服务端不暴露存在性
- 启用但 `MCP_API_KEY` 未设置时返回 500（配置错误，而非放行所有人）
- `MCP_API_KEY` 独立于 `ADMIN_PASSWORD` / `FEVER_API_KEY`，可单独轮换
- 未配置 `MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS` 时，**不接受任何
  浏览器 Origin**（防 DNS rebinding）。CLI/SDK 客户端不发送 Origin，所以
  通常只需配 hosts：
  ```bash
  # 例如走 tailscale：
  MCP_ALLOWED_HOSTS=localhost,127.0.0.1,<machine>.<tailnet>.ts.net
  ```

## 客户端接入

任何 MCP 客户端（Claude Desktop、Cursor、自写 agent）配置：

```
server:   http://<earss-host>:4000/mcp
auth:     Bearer <MCP_API_KEY>
protocol: 2026-07-28 (preferred)
```

`server/discover` 会返回服务名 `earss`、支持的协议版本、能力清单。

## 工具

### 查询（只读）

| 工具 | 说明 |
|---|---|
| `entry_list` | 时间线，excerpt + 已读/加星状态内联；可按 feed/分类/未读/加星过滤 |
| `entry_search` | 标题/正文关键词搜索，支持中/英/日（PGroonga）或降级 ILIKE |
| `entry_get` | 单条完整正文 |
| `feed_list` | 订阅列表 + 未读数 + feed 健康状态 |
| `container_list` | 已采集的容器 feed |
| `ping` | 健康检查 |

### 阅读状态

`entry_mark_read` / `entry_mark_unread` / `entry_star` / `entry_unstar`、
`entry_mark_read_batch`（按 ids / feed / 分类批量标已读，可带 `before` 时间）

### 翻译 / TTS 手动控制

采集与抓取会自动触发管线，但也可以手动控制（feed 级与 entry 级）：

| 工具 | 作用 |
|---|---|
| `translate_feed` | 立即翻译某 feed 所有待翻译条目（含暂停的） |
| `translate_entry` | 立即翻译单篇 |
| `translation_publish_original` | 放弃翻译、发布原文（⚠️ 破坏性，两阶段确认） |
| `tts_request` | 把某篇加入音频合成队列（幂等） |
| `tts_requeue` | 重试失败的合成 |
| `tts_delete` | 删除合成请求 + 音频文件（⚠️ 破坏性，两阶段确认） |

> `translation_publish_original` 和 `tts_delete` 走两阶段确认：
> 先返回影响报告，`confirm: true` 才执行。

### 采集入库（需求 2）

`ingest_items` 把 agent 采集的内容存入**容器 feed**（`feed_type: "manual"`，
从不被抓取），并可触发既有管线：

```json
{
  "container": "research/2026Q3",
  "items": [
    {"title": "...", "link": "https://...", "content": "<p>...</p>", "published_at": "..."}
  ],
  "pipeline": {"translate_to": "zh", "tts": true}
}
```

- 按 `link`（或 `guid`）去重；重采同 URL 是更新而非复制
- 内容经过 `HTMLSanitize`（与正常抓取一致）
- `translate_to` → 走 `Enrichment.PendingWorker`（自动重试）
- `tts` → 走 `TTS.Worker`（自动合成 + 重试）

`feed_backfill` 通过插件可选 `backfill/2` 回调抓取 RSS 窗口外的历史内容；
不支持该能力的源会明确报错而非静默。

### 订阅管理

`feed_subscribe` / `feed_unsubscribe` / `feed_update` / `feed_refresh`

### 分类与 OPML

`category_list` / `category_create` / `category_update` / `category_delete`、
`opml_export` / `opml_import`

### 系统状态

`system_status` / `feed_stats` / `translation_status` / `tts_list`

## 破坏性操作（两阶段确认）

删除类工具（`feed_unsubscribe`、`category_delete`、`opml_import`）是
**两阶段执行**：

1. 不带 `confirm: true` 调用 → 返回**影响报告**（会删什么、影响多少），
   **不执行任何操作**
2. 带 `confirm: true` 调用 → 才真正执行

```json
// 第一次调用（预览）：
{"name": "feed_unsubscribe", "arguments": {"feed_id": 2}}
// → {"executed": false, "requires_confirmation": true,
//    "affected": "subscription", "feed_title": "...",
//    "entries_losing_read_state": 17, ...}

// 确认后：
{"name": "feed_unsubscribe", "arguments": {"feed_id": 2, "confirm": true}}
// → {"unsubscribed": true}
```

影响报告由服务端强制，不依赖客户端弹窗（很多客户端不实现该注解）。
工具同时带 `destructiveHint` 标准注解，支持它的客户端会额外提示。
`MCP_READ_ONLY=true` 时所有写工具从 `tools/list` 隐藏并被拒绝调用。

## 搜索（PGroonga）

`entry_search` 默认用 **PGroonga**（nixpkgs 有
`postgresql16Packages.pgroonga`），其 `TokenBigram` 分词器天然支持中/英/日
混合。NixOS 启用：

```nix
services.earss.database.searchExtensions = true;
```

未安装扩展的部署（CI、docker compose）自动降级为 `ILIKE`，工具响应会标注
`"search_mode": "ilike"`。

## 测试

```bash
mix test test/earss/mcp
```

覆盖：鉴权（缺失/错误/未配置）、协议往返（discover/list/call）、只读门、
excerpt/HTML 剥离、容器不可抓取、去重、sanitize、管线触发、backfill 契约。
