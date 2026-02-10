defmodule Earss.Repo.Migrations.CreateCategories do
  @moduledoc """
  创建分类表 (categories)

  ## 设计说明

  - 每个用户有多个分类用于组织订阅
  - "all" 分类为虚拟聚合视图（应用层实现），无需存储
  - 用户可自行创建自定义分类
  - 订阅可以不属于任何分类（category_id 为 NULL），仍会在 "all" 视图中显示

  ## 字段说明

  - `name` - 分类名称
  - `user_id` - 所属用户（外键）

  ## 索引

  - `unique_index([:user_id, :name])` - 同一用户下分类名不能重复
  """
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :name, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:categories, [:user_id, :name])
  end
end
