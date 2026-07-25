# Admin v0.2 工作进展（临时）

> 临时工作记录。**Slice 1–3 与测试/文档已完成**；可删除本文件或保留作回顾。  
> 更新时间：2026-07-25

---

## 目标范围（已确认）

| 项 | 决定 |
|----|------|
| 方向 | 源管理增强 + 运维可观测（不做 Web 阅读器） |
| 订阅编辑 | **详情页** `/admin/subscriptions/:id` |
| System + retention | **进 v0.2**；全局清理 **仅 admin** |
| 批量 Refresh | **P1**（上限 20） |
| 实施顺序 | Slice 1 → 2 → 3 |

不改 schema；复用 `Reader` / `Feeds` / `FeedScheduler` / `Retention`。

---

## 完成清单

- [x] **Slice 1 — 源管理可编辑**
  - [x] `GET/POST /admin/subscriptions/:id`（title / interval / category / hidden）
  - [x] 列表：`?q=&category_id=&status=&sort=` + 状态列
  - [x] 详情页 feed 只读调度信息 + Refresh / Re-enable
  - [x] 错误 flash 可读化（changeset）
  - [x] Admin 测试：编辑订阅 + 列表筛选
- [x] **Slice 2 — 运维可视**
  - [x] Feeds 健康表 + `status=all|active|disabled|error|due` + search
  - [x] Dashboard 可点 stat + problem/due 列表
  - [x] 单源 Refresh / Re-enable 接到详情与列表
- [x] **Slice 3 — System + Categories + 批量**
  - [x] `/admin/system` 配置只读 + due 快照
  - [x] Retention dry_run / run，**仅 admin**
  - [x] Categories：重命名、position、订阅数
  - [x] 批量 Refresh（上限 20）
- [x] **收尾**
  - [x] `docs/admin.md`、`docs/roadmap.md`、`README.md`
  - [x] `test/earss/admin_test.exs` 扩展（7 tests）
  - [x] `lib/earss/admin/{auth,html,router}.ex`

---

## 路由一览

```
GET  /admin/subscriptions              # ?q=&category_id=&status=&sort=
GET  /admin/subscriptions/:id
POST /admin/subscriptions/:id          # custom_title, custom_refresh_interval, category_id, is_hidden
GET  /admin/feeds?status=...&q=...
POST /admin/feeds/refresh_batch        # ids[]，上限 20
GET  /admin/system                     # admin only
POST /admin/system/retention           # dry_run | run（admin only）
POST /admin/categories/:id             # rename / position
```

---

## 刻意不做（边界）

- 完整 Web 阅读 UI  
- 改 DB schema  
- CSRF（公网暴露前另做）  
- OpenAPI / 中文 i18n  
