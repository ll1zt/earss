defmodule Earss.Repo.Migrations.CreateSubscriptions do
  @moduledoc """
  创建订阅关系表 (subscriptions)

  ## 设计说明

  - 连接用户和 Feed，实现多对多关系
  - 每个用户可以订阅多个 Feed，每个 Feed 可以被多个用户订阅
  - 用户可以为订阅设置自定义标题和刷新间隔
  - 订阅可以归属到不同分类进行组织，也可以不属于任何分类（category_id = NULL）
  - 删除分类时，订阅的 category_id 自动设为 NULL，仍在 "all" 视图中可见

  ## 字段说明

  - `user_id` - 订阅用户（外键）
  - `feed_id` - 订阅的 Feed（外键）
  - `category_id` - 所属分类（外键，可为 NULL，删除分类时自动置空）
  - `custom_title` - 自定义 Feed 显示名称
  - `custom_refresh_interval` - 自定义刷新间隔（分钟）

  ## 索引

  - `unique_index([:user_id, :feed_id])` - 同一用户不能重复订阅同一 Feed
  - `index([:user_id])` - 查询用户的所有订阅
  - `index([:feed_id])` - 查询 Feed 的所有订阅者
  - `index([:category_id])` - 查询分类下的所有订阅
  """
  use Ecto.Migration

  def change do
    create table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :category_id, references(:categories, on_delete: :nilify_all)
      add :custom_title, :string
      add :custom_refresh_interval, :integer
      add :is_hidden, :boolean, default: false, null: false

      timestamps()
    end

    create unique_index(:subscriptions, [:user_id, :feed_id])
    create index(:subscriptions, [:user_id])
    create index(:subscriptions, [:feed_id])
    create index(:subscriptions, [:category_id])
  end
end
