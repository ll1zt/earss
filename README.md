# Earss

Elixir 自托管 RSS / Atom / JSON Feed 阅读器后端。

当前里程碑：**db-schema-v1**（数据模型与迁移已冻结，抓取/调度/API 尚未实现）。

## 要求

- Elixir ~> 1.18
- PostgreSQL（需允许 `citext` 扩展）

## 数据库

```bash
# 配置见 config/dev.exs、config/test.exs
mix deps.get
mix ecto.create
mix ecto.migrate
```

测试：

```bash
mix test
```

## 文档

- [数据模型](docs/data_model.md)
- [数据生命周期](docs/data_lifecycle.md)
- [调度设计（下阶段）](docs/feed_scheduler_guide.md)

## 架构摘要

- **Feeds context**：全局 feed / entry（共享抓取与存储）
- **Reader context**：用户、分类、订阅、阅读状态

## License

见 [LICENSE](LICENSE)。
