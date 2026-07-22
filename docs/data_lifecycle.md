# Earss 数据生命周期（db-schema-v1）

与 `data_model.md` 配套。业务 context 实现时必须遵守下列副作用；**本阶段不在数据库写触发器**。

## 1. 用户

| 事件 | 行为 |
|------|------|
| 创建 admin / sub_user | 写入 `password_hash`；`user_type` 合法；默认 `is_active=true` |
| 禁用 | `is_active=false`；鉴权拒绝 |
| 删除用户 | FK 级联删除 categories、subscriptions、entry_states；对曾订阅的 feed 若订阅数归零则设 `last_unsubscribed_at` |

## 2. 分类

| 事件 | 行为 |
|------|------|
| 创建 | `(user_id, name)` 唯一；可设 `position` |
| 删除 | 其下 subscription 的 `category_id` → NULL（仍出现在 all） |

## 3. 订阅

| 事件 | 行为 |
|------|------|
| 订阅 | 若 feed 不存在则先创建 feed；插入 subscription；**清空** `feed.last_unsubscribed_at`；建议将 `next_fetch_at` 设为立即以尽快首抓 |
| 退订 | 删除该 user 在该 feed 下所有 entry 的 `entry_states`；删除 subscription；若该 feed 不再有任何 subscription → `last_unsubscribed_at = utc_now` |
| 隐藏 | `is_hidden=true`：列表可隐藏，但仍计为订阅者（继续抓取）；**不参与** D1 最小间隔聚合时是否计入：约定 **隐藏订阅不参与 min 聚合** |

## 4. Feed 抓取字段约定（实现阶段）

| 结果 | 字段更新（约定） |
|------|------------------|
| 成功有新内容 | `last_fetched_at`、`next_fetch_at`、`error_count=0`、`last_error=null`、`unchanged_fetch_count=0`、缩短 `refresh_interval`、更新 etag/hash、`last_new_entry_at` |
| 成功无新内容 | 类似成功，但 `unchanged_fetch_count++`、拉长间隔 |
| HTTP 304 / hash 相同 | 同无新内容 |
| 失败 | `error_count++`、`last_error`、退避 `next_fetch_at`；达阈值可 `is_active=false` |

调度候选：

```text
is_active = true
AND next_fetch_at <= now()
AND EXISTS (subscription for feed)
AND last_unsubscribed_at IS NULL
```

（`last_unsubscribed_at IS NULL` 与 exists 订阅应同时成立；实现时二选一为主、另一作护栏即可。）

## 5. Entry 写入

- guid 规范化：trim；空则用 link；仍空则丢弃。
- `ON CONFLICT (feed_id, guid) DO UPDATE` 可变字段：title、author、summary、content、link、published_at、content_hash。
- 不修改既有 `entry_states`。

## 6. 阅读状态（懒创建）

| 事件 | 行为 |
|------|------|
| 标已读 | upsert state：`is_read=true`；若无 `read_at` 则设为 now |
| 标未读 | upsert：`is_read=false`，`read_at=null` |
| 星标 / 取消星标 | upsert：`is_star` |
| 从未操作 | 无行，列表视为未读 |

## 7. 清理任务

### Level A — 删除过期 state

```text
is_read = true
AND is_star = false
AND read_at < now() - retention.read_state_days  -- 默认 90
```

### Level B — 删除可回收 entry

在 Level A 之后，删除同时满足：

1. 不存在 `is_star = true` 的 state  
2. 不存在 `is_read = false` 的 state  
3. `inserted_at < now() - retention.entry_days`（默认 180）

**禁止**：仅因「没有任何 entry_state」且仍在保留窗口内而删除。

### 零订阅 feed

```text
last_unsubscribed_at IS NOT NULL
AND last_unsubscribed_at < now() - retention.unsubscribed_feed_days  -- 默认 30
→ DELETE feed（级联 entries 等）
```

## 8. 级联一览

| 删除 | 结果 |
|------|------|
| user | categories、subscriptions、entry_states |
| feed | entries、subscriptions；（entries → entry_states） |
| entry | entry_states |
| category | subscriptions.category_id = NULL |

## 9. 与代码阶段的边界

本生命周期文档在 **db-schema-v1** 冻结规则；`Earss.Feeds` / 调度 / 清理 job 在后续阶段实现，但不得违反本文。
