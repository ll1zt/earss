defmodule Earss.Repo.Migrations.CreateUsers do
  @moduledoc """
  创建用户表 (users)

  ## 设计说明

  - 支持单用户场景，保留多用户扩展能力
  - 通过 `user_type` 区分 admin 和 sub_user
  - admin 拥有所有权限，sub_user 权限受限
  - 未来扩展时可添加 `parent_user_id` 和 `permissions` 字段

  ## 字段说明

  - `username` - 用户名（唯一）
  - `password_hash` - 密码哈希
  - `user_type` - 用户类型：`"admin"` | `"sub_user"`

  ## 索引

  - `unique_index([:username])` - 确保用户名唯一
  - `index([:user_type])` - 加速用户类型查询
  """
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :password_hash, :string, null: false
      add :user_type, :string, default: "admin", null: false

      timestamps()
    end

    create unique_index(:users, [:username])
    create index(:users, [:user_type])
  end
end
