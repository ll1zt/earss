defmodule Earss.Repo.Migrations.CreateEntryStates do
  @moduledoc """
  创建用户条目状态表 (entry_states)

  ## 设计说明

  - 存储用户对条目的个性化状态（已读、星标）
  - 与 entries 表分离，实现内容与状态的解耦
  - 多用户订阅同一 Feed 时，每个用户有独立的阅读状态
  - read_at 字段用于计算自动清理时间（read_at + 90天）

  ## 字段说明

  - `user_id` - 所属用户（外键）
  - `entry_id` - 关联条目（外键）
  - `is_read` - 是否已读
  - `is_star` - 是否星标
  - `read_at` - 首次标记为已读的时间（用于计算自动清理）

  ## 索引

  - `unique_index([:user_id, :entry_id])` - 每个用户对每个条目只有一个状态记录
  - `index([:user_id, :is_read, :is_star])` - 查询用户的阅读状态（已读/未读/星标）
  - `index([:entry_id])` - 反向查询条目的阅读用户
  - `index([:user_id, :is_read], where: "is_read = false")` - 查询未读条目（高频查询优化）
  - `index([:user_id, :is_star], where: "is_star = true")` - 查询星标条目
  - `index([:read_at], where: "is_read = true AND is_star = false")` - 定时清理任务查询待删除条目
  """
  use Ecto.Migration

  def change do
    create table(:entry_states) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :entry_id, references(:entries, on_delete: :delete_all), null: false
      add :is_read, :boolean, default: false, null: false
      add :is_star, :boolean, default: false, null: false
      add :read_at, :utc_datetime
      
      timestamps()
    end

    create unique_index(:entry_states, [:user_id, :entry_id])
    create index(:entry_states, [:user_id, :is_read, :is_star])
    create index(:entry_states, [:entry_id])
    create index(:entry_states, [:user_id, :is_read], where: "is_read = false")
    create index(:entry_states, [:user_id, :is_star], where: "is_star = true")
    create index(:entry_states, [:read_at], where: "is_read = true AND is_star = false")
  end
end
