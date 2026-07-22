defmodule Earss.Repo.Migrations.CreateSubscriptions do
  @moduledoc """
  创建 subscriptions 表（用户 ↔ Feed）。
  """
  use Ecto.Migration

  def change do
    create table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :category_id, references(:categories, on_delete: :nilify_all)
      add :custom_title, :text
      add :custom_refresh_interval, :integer
      add :is_hidden, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subscriptions, [:user_id, :feed_id])
    create index(:subscriptions, [:user_id])
    create index(:subscriptions, [:feed_id])
    create index(:subscriptions, [:category_id])
    create index(:subscriptions, [:user_id, :is_hidden])

    create constraint(:subscriptions, :subscriptions_custom_refresh_interval_positive,
      check: "custom_refresh_interval IS NULL OR custom_refresh_interval > 0"
    )
  end
end
