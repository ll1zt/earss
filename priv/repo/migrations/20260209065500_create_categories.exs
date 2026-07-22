defmodule Earss.Repo.Migrations.CreateCategories do
  @moduledoc """
  创建 categories 表（用户自定义分类；「all」不落库）。
  """
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :name, :text, null: false
      add :position, :integer, null: false, default: 0
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:categories, [:user_id, :name])
    create index(:categories, [:user_id, :position])
  end
end
