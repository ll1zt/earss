defmodule Earss.Repo.Migrations.CreateEntries do
  @moduledoc """
  创建 Feed 条目表 (entries)

  ## 设计说明

  - 存储从 Feed 抓取的文章/条目内容
  - 条目独立于用户，多用户订阅时共享数据（节省存储）
  - 使用 guid 作为唯一标识（Feed 提供）
  - 自动清理机制：基于 entry_states 驱动，删除 read_at + 90天且未 star 的条目，
    然后清理没有任何 entry_state 的孤儿条目

  ## 字段说明

  ### 关联
  - `feed_id` - 所属 Feed（外键）

  ### 唯一标识
  - `link` - 条目链接
  - `guid` - 全局唯一标识（由 Feed 提供）

  ### 内容信息
  - `title` - 标题
  - `author` - 作者
  - `summary` - 摘要
  - `content` - 完整内容
  - `published_at` - 发布时间

  ## 索引

  - `unique_index([:feed_id, :guid])` - 同一 Feed 下 guid 唯一
  - `index([:feed_id, :published_at])` - 按发布时间查询 Feed 的条目
  - `index([:published_at])` - 全局按时间排序
  - `index([:link])` - 按链接查询
  """
  use Ecto.Migration

  def change do
     create table(:entries) do
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :link, :string, null: false
      add :guid, :string, null: false
      add :title, :string
      add :author, :string
      add :summary, :text
      add :content, :text
      add :published_at, :utc_datetime

      timestamps()
    end

    create unique_index(:entries, [:feed_id, :guid])
    create index(:entries, [:feed_id, :published_at])
    create index(:entries, [:published_at])
    create index(:entries, [:inserted_at])
    create index(:entries, [:link])
  end
end
