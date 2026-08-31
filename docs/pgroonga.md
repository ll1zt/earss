# PGroonga：多语言全文搜索

`entry_search` 的默认检索后端是 **PGroonga**。它让标题/正文的中文、日文、
英文**在同一列里混合搜索**并给出相关度排序——这是 PostgreSQL 内置
`tsvector` 做不到的（内置 FTS 没有 CJK 分词器）。

没有 PGroonga 时，`entry_search` 自动降级为 `ILIKE` 模糊匹配：功能可用，
但**无相关度排序**，且大表上是顺序扫描。工具响应会如实标注
`"search_mode": "ilike"`（有 PGroonga 时是 `"search_mode": "pgroonga"`）。

> 一句话：**不装能用，装了更好。** 启用是可选项，永远不会让 earss 起不来。

---

## 原理

PGroonga 的默认分词器是 `TokenBigram`：

- **非 ASCII 字符**（中日韩）→ bigram 切分
- **ASCII 字符**（英文）→ 按空格切分

所以同一列混排多语言**零配置**。相关度用 `pgroonga_score` 计算，一个词
同时命中标题和正文会比只命中一处得分更高。

```sql
-- 索引（迁移 20260830130000 在扩展可用时自动创建）
CREATE INDEX entries_search_idx ON entries
  USING pgroonga (title, content, summary);

-- 查询（Earss.MCP.Search 内部用的形式）
SELECT id, pgroonga_score(tableoid, ctid) AS rank
FROM entries
WHERE title &@~ $1 OR content &@~ $1 OR summary &@~ $1
ORDER BY rank DESC;
```

---

## 启用方式

按部署形态选一条：

### A. NixOS（推荐，声明式）

在宿主 flake 里启用：

```nix
services.earss.database.searchExtensions = true;
```

模块会：

1. 把 pgroonga 加进 `services.postgresql.extensions`
2. 用 `package.withPackages` **按当前 PG 版本重新编译**（扩展与 PG 的 ABI
   必然匹配，不会出现「装上了但 .so 加载失败」）
3. 在首次启动的 `earss-postgres-setup` unit 里执行
   `CREATE EXTENSION IF NOT EXISTS pgroonga`

> **为什么是函数形式而不是指定版本号**：如果写死
> `postgresql16Packages.pgroonga`，而系统实际用的是 PG 17/18，扩展的 `.so`
> 与 PG 二进制 ABI 不匹配，会**构建成功但运行期崩**。函数形式让扩展版本
> 跟随 `services.postgresql.package`，永远匹配。

应用后：

```bash
nixos-rebuild switch
# 重建后确认扩展和索引已就位：
psql -d <db> -c '\dx pgroonga'
psql -d <db> -c '\di entries_search_idx'
```

### B. 手动裸机（非 NixOS，本机实操路径）

前提：PostgreSQL 18.x（本机是 18.4，由 nix 管理但手动启动）。

**1. 构建带 pgroonga 的 PG 包**（Nix 环境）：

```bash
nix build --impure --expr \
  'let pkgs = import <nixpkgs> { system = "x86_64-linux"; };
   in pkgs.postgresql_18.withPackages (ps: [ ps.pgroonga ])' \
  --no-link --print-out-paths
# → /nix/store/xxx-postgresql-and-plugins-18.4
```

**2. 备份数据**（切换二进制前的基本纪律）：

```bash
pg_dump -F c -d earss_dev -f ~/earss-backups/earss_dev_$(date +%F).dump
```

**3. 干净切换**（顺序很重要：先停应用 → 干净停 PG → 用新二进制启动）：

```bash
# 停 earss（如果它在跑）
# 用旧 PG 的 pg_ctl 干净关库（保证 WAL 落盘）
<nix>/bin/pg_ctl -D <datadir> -m fast stop

# 用带 pgroonga 的新 PG 启动，参数与原来完全一致
nohup <new-nix>/bin/postgres -D <datadir> -k /tmp &

# 确认版本与扩展可用
psql -d earss_dev -c 'SELECT version();'
psql -d earss_dev -c "SELECT name FROM pg_available_extensions WHERE name='pgroonga';"
```

> 同版本（18.4 → 18.4）换二进制，数据目录零迁移、直接兼容。跨大版本
> （如 16 → 18）则必须先 `pg_upgrade` 或 dump/restore。

**4. 建扩展 + 索引**：

```bash
psql -d earss_dev -c 'CREATE EXTENSION IF NOT EXISTS pgroonga;'
psql -d earss_dev -c 'CREATE INDEX IF NOT EXISTS entries_search_idx
  ON entries USING pgroonga (title, content, summary);'
```

> 迁移 `20260830130000` 会在扩展可用时自动建索引。如果你是在迁移**已经**
> 跑过（当时扩展缺失、被跳过）之后才装扩展，就需要手动执行上面这条
> `CREATE INDEX`（迁移记录不会重跑）。

**5. 重启 earss**，然后验证：

```bash
curl -s -X POST http://localhost:4000/mcp \
  -H 'Content-Type: application/json' -H 'Authorization: Bearer <key>' \
  -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/call' \
  -H 'Mcp-Name: entry_search' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",
       "params":{"name":"entry_search","arguments":{"query":"测试"},
         "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
                  "io.modelcontextprotocol/clientInfo":{"name":"t","version":"1"},
                  "io.modelcontextprotocol/clientCapabilities":{}}}}'
# 响应里应有 "search_mode":"pgroonga" 和 "ranked":true
```

### C. Docker Compose

`docker-compose.yml` 的 `db` 服务默认用 `postgres:16-alpine`（官方镜像，
**不带** pgroonga）。启用需要换成带扩展的自定义镜像：

```yaml
# docker-compose.yml 的 db 服务改为 build（而非直接拉官方镜像）
db:
  build: ./docker/pgroonga
  # 其余配置（volume、env）保持不变
```

`docker/pgroonga/Dockerfile`（基于官方镜像装扩展）：

```dockerfile
# 注意：镜像的 PG 版本必须与你要装的 pgroonga 匹配
FROM postgres:16-alpine
# Alpine 需要构建依赖；或用发行版预编译包。这里给思路：
RUN apk add --no-cache build-base postgresql-dev groonga-dev && \
    # 下载 pgroonga 源码，./configure --with-pg-config=/usr/local/bin/pg_config \
    # && make && make install
```

> 镜像一旦包含 pgroonga，在 `/docker-entrypoint-initdb.d/` 放一个 SQL 脚本
> 让官方 entrypoint 首次启动时自动建扩展：
>
> ```sql
> -- docker-entrypoint-initdb.d/010-pgroonga.sql
> CREATE EXTENSION IF NOT EXISTS pgroonga;
> ```

---

## 验证清单

| 检查 | 命令 | 期望 |
|---|---|---|
| 扩展已装 | `psql -d <db> -c '\dx pgroonga'` | `pgroonga \| 4.0.5` |
| 索引存在 | `psql -d <db> -c '\di entries_search_idx'` | `using pgroonga` |
| 运算符可用 | `psql -d <db> -c "SELECT count(*) FROM entries WHERE content &@~ 'test';"` | 返回数字而非报错 |
| 工具用上了 | MCP 调 `entry_search` | `"search_mode":"pgroonga"`, `"ranked":true` |

---

## 故障排查

### `search_mode` 仍是 `ilike`

可能原因与对策：

| 现象 | 原因 | 对策 |
|---|---|---|
| `pg_available_extensions` 里没有 pgroonga | PG 二进制没打包扩展 | 换 `withPackages` 构建的包（见上文） |
| 扩展装了但搜索仍 ilike | `Search.mode()` 查的是 `pg_extension`（当前库） | 确认在**同一数据库**里 `CREATE EXTENSION` |
| 新装的扩展，索引没建 | 迁移早于装扩展跑过 | 手动 `CREATE INDEX IF NOT EXISTS entries_search_idx ...` |

### 扩展加载失败（ABI 错配）

```
could not load library ".../pgroonga.so": incompatible library
```

PG 版本与扩展编译目标版本不一致。**不要手动把 .so 拷进 PG 的 lib 目录**
（nix store 只读，且版本对不上照样崩）。正确做法永远是用
`withPackages`（或 NixOS `extensions` 函数形式）让版本匹配。

### 服务起不来

先确认是 PG 的问题还是 earss 的问题：

```bash
# PG 侧
psql -d earss_dev -c 'SELECT 1;'   # 连不上 → 看 PG 日志
# earss 侧
tail -f /tmp/earss.log             # 看应用日志
```

---

## 降级

任何时候移除 PGroonga（卸载扩展、删索引、换回无扩展的 PG），earss **无需
改动**：`entry_search` 自动回到 ILIKE 模式并在响应标注
`"search_mode": "ilike"`。代码不存在对 pgroonga 的硬依赖。

```sql
-- 如需彻底移除（可选）
DROP INDEX IF EXISTS entries_search_idx;
DROP EXTENSION IF EXISTS pgroonga;
```

> 注意：`DROP EXTENSION pgroonga` 会连带删掉依赖它的索引，所以顺序可颠倒，
> 但先删索引更干净。

---

## 测试

测试套件同时覆盖两种模式（`test/support` 不强制扩展）：

- 装了扩展的库 → `entry_search` 测试跑 **ranked** 分支
- 没装的库 → 同一测试跑 **ilike** 分支

两者都断言 `search_mode` 与结果自洽，所以 CI 无论有没有 PGroonga 都能过。
详见 `test/earss/mcp/tools/reading_test.exs`。
