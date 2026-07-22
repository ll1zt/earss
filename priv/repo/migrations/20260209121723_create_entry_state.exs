defmodule Earss.Repo.Migrations.CreateEntryStates do
  @moduledoc """
  创建 entry_states 表（懒创建；见 docs/data_lifecycle.md）。
  """
  use Ecto.Migration

  def change do
    create table(:entry_states) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :entry_id, references(:entries, on_delete: :delete_all), null: false
      add :is_read, :boolean, null: false, default: false
      add :is_star, :boolean, null: false, default: false
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:entry_states, [:user_id, :entry_id])
    create index(:entry_states, [:user_id, :is_read, :is_star])
    create index(:entry_states, [:entry_id])

    create index(:entry_states, [:user_id, :is_read],
      where: "is_read = false",
      name: :entry_states_user_unread_index
    )

    create index(:entry_states, [:user_id, :is_star],
      where: "is_star = true",
      name: :entry_states_user_starred_index
    )

    create index(:entry_states, [:read_at],
      where: "is_read = true AND is_star = false",
      name: :entry_states_cleanup_read_at_index
    )

    create constraint(:entry_states, :entry_states_read_at_consistency,
      check: """
      (is_read = false AND read_at IS NULL)
      OR (is_read = true AND read_at IS NOT NULL)
      """
    )
  end
end
