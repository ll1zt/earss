# Earss 数据模型（db-schema-v1）

本文档是数据库阶段的**单一事实来源**。字段名、默认值、约束以本文 + migrations 为准。

## 设计原则

1. 内容全局共享（`feeds` / `entries`），状态与偏好按用户隔离。
2. 表结构服务真实查询：调度、未读、星标、清理。
3. URL / 长文本使用 `text`；时间统一 `utc_datetime`。
4. 不预建未使用的扩展表（enclosure、token、权限等）。

## 冻结决策 D1–D7

| ID | 决策 |
|----|------|
| D1 | 多用户刷新：取未隐藏订阅的 `custom_refresh_interval` 与 feed 策略的**最小有效间隔**，再 clamp 到 feed 的 min/max。全局只抓一份。 |
| D2 | `entry_states` **懒创建**：仅在标记已读/星标等操作时 upsert。「未读」= 无行或 `is_read = false`。 |
| D3 | 零订阅 feed：停止调度；写 `last_unsubscribed_at`；超过 `retention.unsubscribed_feed_days`（默认 30）可删。 |
| D4 | 同 `(feed_id, guid)` 允许更新可变内容；`content_hash` 辅助判断；不重置用户 state。 |
| D5 | URL/guid/标题/正文等为 `text`；枚举用短 string + check；`timestamps(type: :utc_datetime)`。 |
| D6 | 清理分两级：A 过期已读未星标 state（90 天）；B 全局可回收 entry（180 天等条件）。**禁止**「无 state 即删」。 |
| D7 | 默认间隔 30 分钟，min 15，max **10080**（7 天）。 |

## ER

```
users
  ├── categories
  ├── subscriptions ── feeds ── entries
  │         │                      │
  │         └── category (optional)│
  └── entry_states ────────────────┘
```

## 表：users

| 字段 | 类型 | 说明 |
|------|------|------|
| id | bigserial | PK |
| username | citext | 唯一，大小写不敏感 |
| password_hash | text | Argon2 等哈希 |
| user_type | string | `admin` \| `sub_user` |
| is_active | boolean | 默认 true |
| inserted_at / updated_at | utc_datetime | |

- 唯一：`username`
- Check：`user_type IN ('admin','sub_user')`
- 级联：删 user → categories / subscriptions / entry_states

## 表：feeds

| 字段 | 类型 | 默认 | 说明 |
|------|------|------|------|
| link | text | | Feed URL，唯一 |
| feed_type | string | rss | rss \| atom \| json |
| site_url | text | | |
| title / description | text | | |
| last_fetched_at / next_fetch_at | utc_datetime | | 调度 |
| refresh_interval | int | 30 | 当前间隔（分钟） |
| min_refresh_interval | int | 15 | |
| max_refresh_interval | int | 10080 | |
| unchanged_fetch_count | int | 0 | |
| error_count | int | 0 | |
| last_error | text | | |
| etag / last_modified | text | | HTTP 缓存 |
| last_fetched_content_hash | text | | body hash |
| is_active | boolean | true | 熔断/禁用 |
| last_unsubscribed_at | utc_datetime | null | 零订阅起算 |
| last_new_entry_at | utc_datetime | null | 最近新条目 |
| timestamps | utc_datetime | | |

索引：

- `unique(link)`
- `(is_active, next_fetch_at)` 调度主索引
- partial `(last_unsubscribed_at) WHERE last_unsubscribed_at IS NOT NULL`

Check：间隔为正；`max >= min`；`feed_type` 枚举；计数 >= 0。

调度查询还必须限制「仍存在 subscription」（实现阶段）。

## 表：entries

| 字段 | 类型 | 说明 |
|------|------|------|
| feed_id | FK → feeds | ON DELETE CASCADE |
| link / guid | text | 必填；guid 应用层可 fallback 为 link |
| title / author / summary / content | text | |
| published_at | utc_datetime | |
| content_hash | text | 同 guid 更新判断 |
| timestamps | utc_datetime | |

- 唯一：`(feed_id, guid)`
- 索引：`(feed_id, published_at)`、`(published_at)`、`(inserted_at)`

## 表：categories

| 字段 | 类型 | 说明 |
|------|------|------|
| user_id | FK → users | CASCADE |
| name | text | 同用户唯一 |
| position | int | 默认 0，排序 |
| timestamps | utc_datetime | |

「all」为虚拟视图，不落库。

## 表：subscriptions

| 字段 | 类型 | 说明 |
|------|------|------|
| user_id | FK → users | CASCADE |
| feed_id | FK → feeds | CASCADE |
| category_id | FK → categories | NULL，ON DELETE SET NULL |
| custom_title | text | |
| custom_refresh_interval | int \| null | 分钟，null=跟随 feed |
| is_hidden | boolean | 默认 false |
| timestamps | utc_datetime | |

- 唯一：`(user_id, feed_id)`
- Check：`custom_refresh_interval IS NULL OR > 0`

## 表：entry_states

| 字段 | 类型 | 说明 |
|------|------|------|
| user_id | FK → users | CASCADE |
| entry_id | FK → entries | CASCADE |
| is_read | boolean | 默认 false |
| is_star | boolean | 默认 false |
| read_at | utc_datetime | 首次已读时间 |
| timestamps | utc_datetime | |

- 唯一：`(user_id, entry_id)`
- Check：未读则 `read_at IS NULL`；已读则 `read_at IS NOT NULL`
- Partial 索引：未读、星标、清理用 `read_at`

## 配置键

```elixir
config :earss, :refresh,
  min_interval: 15,
  max_interval: 10_080,
  default_interval: 30

config :earss, :retention,
  read_state_days: 90,
  entry_days: 180,
  unsubscribed_feed_days: 30
```

## 版本

- Tag 目标：`db-schema-v1`
- 对应决策方案默认值（2026-07）
