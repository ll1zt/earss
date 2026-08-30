# TODO

## Refactor: 模块过大 / 职责过粗

- [x] `lib/earss/enrichment.ex` —— 去重（code review 后续）：
      `fresh?/3` 统一 freshness 判定；`clear_pending`/`retry_paused`/
      `publish_pending` 收敛到 `update_feed_entries/3`。
- [ ] `lib/earss/enrichment.ex` 仍 ~700 行，可继续切分：
      - pending 查询与 publish 判定 → `Earss.Enrichment.Pending`
      - 目标语言聚合（feed ∪ 订阅）→ `Earss.Enrichment.Languages`
      - 结果校验与存储（ref/type validation）→ `Earss.Enrichment.Store`
      目标：`enrichment.ex` 留编排主干，每个子模块可独立测试。
- [ ] `lib/earss/admin/views/subscriptions.ex` (380 行) —— 视图片按 section 拆
      （列表 / 详情表单 / 批量条），或抽出可复用 partial 到 `Earss.Admin.HTML`。
- [ ] 一并复查「第二梯队」：`lib/earss/greader/subscriptions.ex` (390)、
      `lib/earss/api/authenticated_router.ex` (410)、`lib/earss/retention.ex` (404)、
      `lib/earss/tts/worker.ex` (427)、`lib/earss/admin/controllers/subscriptions.ex` (396)、
      `lib/earss/api/greader.ex` 的 `call/2` (161 行路由分派表)。
      标准不是行数本身，而是「一个模块里是否有两条互不相干的变更理由」。

## 已完成（2026-08-30 code review）

- [x] SSRF：首次请求 URL 纳入 blocklist（此前只拦重定向）
      —— `HTTP.safe_initial_target?/1` + `HTTP_ALLOW_BLOCKED_TARGETS`
- [x] `String.to_atom/1` 死代码清理（`param/2`、`header_value/2`）
- [x] `TTS.Worker.store_audio/4` 原子写（tmp + rename）+ 失败不留孤儿文件
- [x] `fail/4` 不再静默吞异常，改为 error 日志
- [x] 12 个纯 DB 测试套件标 `async: true`；清零全部测试编译警告
- [x] `|> case do` 三处改为「先赋值再 case」
- [x] 6 个 schema 补 `@moduledoc`（现 109/109 全覆盖）
- [x] Admin View 不再自己查 `Enrichment.stats/1`（移到 controller）
- [x] `Enrichment` 移除 4 处内部 DB 调用的预防性 rescue

## 已记录、暂缓

- CI（GitHub Actions）：`mix format --check-formatted` + `mix test` 门禁
      ——现在零警告、零 format diff，是最适合上 CI 的时机
- `erl_crash.dump` 启动期 `badarg` 定位与清理
- `ADMIN_PASSWORD=admin` 本地弱口令
- `Goal2_TODO.md` 位于仓库根目录（已 gitignore，建议移出）
- `.env` 与 `earss.env` 双份 TTS 变量
- 插件仓库契约包依赖方式不统一（`path:` vs `github:` + override）
- `TTS.Worker` 已知限制：异步 job 轮询持有 `Limiter` slot，
      长文合成会串行化（当前靠 `max_chars_sync: 100_000` 规避）
- 10 个提交摘要超 72 字符；2 个早期 `update .gitignore` 裸消息
- 仅 `main` 一个分支：建议 GitHub Flow + branch protection
- 有 `Merge branch 'main' of ...` 提交 —— 改用 `git pull --rebase`
