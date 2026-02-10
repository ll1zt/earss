defmodule Earss.Repo.Migrations.CreateFeeds do
  @moduledoc """
  创建 RSS/Atom/JSON Feed 表 (feeds)

  ## 设计说明

  - Feed 独立于用户，多用户订阅同一 Feed 时共享数据
  - 实现智能动态刷新：根据更新频率自动调整抓取间隔
  - 默认刷新间隔 30 分钟，可动态调整在 15 分钟 ~ 7 天之间
  - 支持 ETag 和 Last-Modified 头，减少带宽消耗

  ## 字段说明

  ### 基础信息
  - `link` - Feed 源地址（唯一）
  - `feed_type` - 类型：`"rss"` | `"atom"` | `"json"`
  - `site_url` - 网站地址
  - `title` - Feed 标题
  - `description` - Feed 描述

  ### 抓取调度
  - `last_fetched_at` - 上次抓取时间
  - `next_fetch_at` - 下次抓取时间
  - `refresh_interval` - 当前刷新间隔（分钟）
  - `min_refresh_interval` - 最短刷新间隔（分钟，默认 15）
  - `max_refresh_interval` - 最长刷新间隔（分钟，默认 10080 即 7 天）

  ### 动态调整机制
  - `unchanged_fetch_count` - 连续未更新次数（用于延长间隔）
  - `error_count` - 连续错误次数（用于暂停抓取）
  - `last_error` - 最后一次错误信息

  ### HTTP 缓存优化
  - `etag` - ETag 响应头
  - `last_modified` - Last-Modified 响应头

  ### 状态控制
  - `is_active` - 是否启用（错误过多时可禁用）

  ## 索引

  - `unique_index([:link])` - 同一 Feed 地址只存储一次
  - `index([:next_fetch_at])` - 调度器查询待抓取的 Feed
  - `index([:is_active, :next_fetch_at])` - 查询激活的待抓取 Feed
  - `index([:is_active, :unchanged_fetch_count])` - 查找需要调整刷新间隔的 Feed
  """
  use Ecto.Migration

  def change do
    create table(:feeds) do
      add :link, :string, null: false
      add :feed_type, :string, default: "rss", null: false
      add :site_url, :string
      add :title, :string
      add :description, :text
      add :last_fetched_at, :utc_datetime
      add :next_fetch_at, :utc_datetime
      add :refresh_interval, :integer, default: 30, null: false
      add :min_refresh_interval, :integer, default: 15, null: false
      add :max_refresh_interval, :integer, default: 10080, null: false
      add :unchanged_fetch_count, :integer, default: 0, null: false
      add :error_count, :integer, default: 0, null: false
      add :last_error, :text
      add :etag, :string
      add :last_modified, :string
      add :last_fetched_content_hash, :string
      add :is_active, :boolean, default: true, null: false

      timestamps()
    end

    create unique_index(:feeds, [:link])
    create index(:feeds, [:next_fetch_at])
    create index(:feeds, [:is_active, :next_fetch_at])
    create index(:feeds, [:is_active, :unchanged_fetch_count])
  end
end
