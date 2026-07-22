# Feed Scheduler 设计指南（实现属于下一阶段）

> **状态：** 设计约定已冻结，与 `data_model.md` / `data_lifecycle.md` 对齐。  
> **本阶段不要求** 存在 `Earss.FeedScheduler` 模块。

## 目标

- 用户可自定义刷新间隔（订阅级 `custom_refresh_interval`）
- Feed 级自适应间隔（`refresh_interval` 在 min/max 间滑动）
- 失败指数退避；连续失败可禁用（`is_active=false`）
- 全局每源只抓一份

## 字段名（以 schema 为准）

| 用途 | 字段 |
|------|------|
| 当前间隔 | `refresh_interval` |
| 下限 / 上限 | `min_refresh_interval` / `max_refresh_interval` |
| 下次抓取 | `next_fetch_at` |
| 连续无新内容 | `unchanged_fetch_count` |
| 连续错误 | `error_count` |
| 熔断 | `is_active` |
| HTTP 缓存 | `etag`, `last_modified`, `last_fetched_content_hash` |

## 有效间隔（D1）

```text
candidates = [feed.refresh_interval 调整前的基准逻辑由实现定义]
           + 所有 is_hidden=false 且 custom_refresh_interval IS NOT NULL 的订阅间隔

effective = clamp(min(candidates), feed.min_refresh_interval, feed.max_refresh_interval)
```

无订阅者：不调度。

## 自适应（建议）

| 场景 | 策略 |
|------|------|
| 成功 + 有新内容 | 间隔 ×0.9，不低于 min |
| 成功 + 无新内容 | 间隔 ×1.2，不高于 max |
| 失败 | 退避 2^n（封顶例如 32×），写 last_error |
| 连续失败达阈值（建议 5） | `is_active=false` |

## 查询待抓取

```elixir
# 伪代码
from f in Feed,
  where: f.is_active == true,
  where: f.next_fetch_at <= ^now,
  where: is_nil(f.last_unsubscribed_at),
  where: fragment("exists (select 1 from subscriptions s where s.feed_id = ?)", f.id),
  order_by: [asc: f.next_fetch_at],
  limit: ^limit
```

## 与配置

见 `config :earss, :refresh` 与 `:retention`。全局默认 max 为 **10080** 分钟。

## 集成建议（下阶段）

- Oban cron 每 N 分钟拉一批，或 GenServer poller
- 并发限制 + 单 feed 超时
- 详见历史草稿中的 Worker 示例思路；实现时字段名必须与本文一致
