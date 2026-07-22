defmodule Earss.Repo.Migrations.CreateFeeds do
  @moduledoc """
  创建 feeds 表（全局 Feed，多用户共享）。

  见 docs/data_model.md
  """
  use Ecto.Migration

  def change do
    create table(:feeds) do
      add :link, :text, null: false
      add :feed_type, :string, null: false, default: "rss"
      add :site_url, :text
      add :title, :text
      add :description, :text
      add :last_fetched_at, :utc_datetime
      add :next_fetch_at, :utc_datetime
      add :refresh_interval, :integer, null: false, default: 30
      add :min_refresh_interval, :integer, null: false, default: 15
      add :max_refresh_interval, :integer, null: false, default: 10_080
      add :unchanged_fetch_count, :integer, null: false, default: 0
      add :error_count, :integer, null: false, default: 0
      add :last_error, :text
      add :etag, :text
      add :last_modified, :text
      add :last_fetched_content_hash, :text
      add :is_active, :boolean, null: false, default: true
      add :last_unsubscribed_at, :utc_datetime
      add :last_new_entry_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feeds, [:link])
    create index(:feeds, [:is_active, :next_fetch_at])

    create index(:feeds, [:last_unsubscribed_at],
      where: "last_unsubscribed_at IS NOT NULL",
      name: :feeds_last_unsubscribed_at_not_null_index
    )

    create constraint(:feeds, :feeds_feed_type_must_be_valid,
      check: "feed_type IN ('rss', 'atom', 'json')"
    )

    create constraint(:feeds, :feeds_intervals_positive,
      check: """
      refresh_interval > 0
      AND min_refresh_interval > 0
      AND max_refresh_interval > 0
      AND max_refresh_interval >= min_refresh_interval
      """
    )

    create constraint(:feeds, :feeds_counts_non_negative,
      check: "unchanged_fetch_count >= 0 AND error_count >= 0"
    )
  end
end
