defmodule Earss.Repo.Migrations.CreateUsers do
  @moduledoc """
  创建 users 表。username 使用 citext（大小写不敏感唯一）。

  见 docs/data_model.md
  """
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"

    create table(:users) do
      add :username, :citext, null: false
      add :password_hash, :text, null: false
      add :user_type, :string, null: false, default: "admin"
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])
    create index(:users, [:user_type])

    create constraint(:users, :users_user_type_must_be_valid,
      check: "user_type IN ('admin', 'sub_user')"
    )
  end
end
