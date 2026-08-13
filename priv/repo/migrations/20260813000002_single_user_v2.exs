defmodule Earss.Repo.Migrations.SingleUserV2 do
  @moduledoc """
  db-schema-v2: drop the per-user dimension (docs/single_user.md).

  * subscriptions / categories / entry_states lose `user_id`; the operator's
    rows (the single anchor user, first row by id) are kept, rows owned by
    other users are deleted (decision D4)
  * per-subscription translation columns are removed (feed-level only, C3)
  * the `users` table is dropped entirely

  The `down` restores the v1 shape but cannot restore the deleted rows of
  non-anchor users — it is best-effort by design.
  """
  use Ecto.Migration

  def up do
    # subscriptions
    execute """
    DELETE FROM subscriptions
    WHERE user_id <> (SELECT min(id) FROM users)
    """

    drop index(:subscriptions, [:user_id, :feed_id])
    drop index(:subscriptions, [:user_id])
    drop index(:subscriptions, [:user_id, :is_hidden])
    drop constraint(:subscriptions, :subscriptions_user_id_fkey)

    alter table(:subscriptions) do
      remove :user_id
      remove :translate_to
      remove :original_layout
    end

    drop index(:subscriptions, [:feed_id])
    create unique_index(:subscriptions, [:feed_id])

    # categories
    execute """
    DELETE FROM categories
    WHERE user_id <> (SELECT min(id) FROM users)
    """

    drop index(:categories, [:user_id, :name])
    drop index(:categories, [:user_id, :position])
    drop constraint(:categories, :categories_user_id_fkey)

    alter table(:categories) do
      remove :user_id
    end

    create unique_index(:categories, [:name])

    # entry_states
    execute """
    DELETE FROM entry_states
    WHERE user_id <> (SELECT min(id) FROM users)
    """

    drop index(:entry_states, [:user_id, :entry_id])
    drop index(:entry_states, [:user_id, :is_read, :is_star])
    execute "DROP INDEX entry_states_user_unread_index"
    execute "DROP INDEX entry_states_user_starred_index"
    drop constraint(:entry_states, :entry_states_user_id_fkey)

    alter table(:entry_states) do
      remove :user_id
    end

    drop index(:entry_states, [:entry_id])
    create unique_index(:entry_states, [:entry_id])

    create index(:entry_states, [:is_read],
      where: "is_read = false",
      name: :entry_states_unread_index
    )

    create index(:entry_states, [:is_star],
      where: "is_star = true",
      name: :entry_states_starred_index
    )

    # users
    drop table(:users)
  end

  def down do
    create table(:users) do
      add :username, :citext, null: false
      add :password_hash, :text
      add :user_type, :string, null: false, default: "admin"
      add :is_active, :boolean, null: false, default: true
      add :fever_api_key, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:fever_api_key])
    create index(:users, [:is_active])

    create constraint(:users, :users_user_type_check,
      check: "user_type IN ('admin', 'sub_user')"
    )

    # re-attach a placeholder operator row (the original rows are gone)
    execute """
    INSERT INTO users (username, password_hash, user_type, inserted_at, updated_at)
    VALUES ('operator', 'operator-anchor', 'admin', now(), now())
    """

    alter table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: true
      add :translate_to, :text
      add :original_layout, :text, null: false, default: "inline"
    end

    execute "UPDATE subscriptions SET user_id = (SELECT min(id) FROM users)"

    alter table(:subscriptions) do
      modify :user_id, :bigint, null: false
    end

    create unique_index(:subscriptions, [:user_id, :feed_id])
    create index(:subscriptions, [:user_id])
    create index(:subscriptions, [:feed_id])
    create index(:subscriptions, [:user_id, :is_hidden])

    alter table(:categories) do
      add :user_id, references(:users, on_delete: :delete_all), null: true
    end

    execute "UPDATE categories SET user_id = (SELECT min(id) FROM users)"

    alter table(:categories) do
      modify :user_id, :bigint, null: false
    end

    create unique_index(:categories, [:user_id, :name])
    create index(:categories, [:user_id, :position])

    alter table(:entry_states) do
      add :user_id, references(:users, on_delete: :delete_all), null: true
    end

    execute "UPDATE entry_states SET user_id = (SELECT min(id) FROM users)"

    alter table(:entry_states) do
      modify :user_id, :bigint, null: false
    end

    drop index(:entry_states, [:entry_id])
    execute "DROP INDEX entry_states_unread_index"
    execute "DROP INDEX entry_states_starred_index"

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
  end
end
