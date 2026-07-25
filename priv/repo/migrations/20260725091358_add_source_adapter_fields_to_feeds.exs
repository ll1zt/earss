defmodule Earss.Repo.Migrations.AddSourceAdapterFieldsToFeeds do
  @moduledoc """
  Additive source-adapter fields for plugin feeds (docs/sources.md Phase S3).
  """
  use Ecto.Migration

  def up do
    alter table(:feeds) do
      add :adapter_id, :text
      add :source_kind, :string, null: false, default: "native"
      add :adapter_cursor, :map
      add :adapter_config, :map
    end

    execute("UPDATE feeds SET adapter_id = 'native' WHERE adapter_id IS NULL")
    execute("UPDATE feeds SET source_kind = 'native' WHERE source_kind IS NULL OR source_kind = ''")

    drop constraint(:feeds, :feeds_feed_type_must_be_valid)

    create constraint(:feeds, :feeds_feed_type_must_be_valid,
      check: "feed_type IN ('rss', 'atom', 'json', 'plugin')"
    )

    create constraint(:feeds, :feeds_source_kind_must_be_valid,
      check: "source_kind IN ('native', 'plugin')"
    )

    create index(:feeds, [:source_kind, :adapter_id])
  end

  def down do
    drop_if_exists index(:feeds, [:source_kind, :adapter_id])
    drop constraint(:feeds, :feeds_source_kind_must_be_valid)

    # Rows with feed_type=plugin would violate the old check; force them back.
    execute("UPDATE feeds SET feed_type = 'rss' WHERE feed_type = 'plugin'")

    drop constraint(:feeds, :feeds_feed_type_must_be_valid)

    create constraint(:feeds, :feeds_feed_type_must_be_valid,
      check: "feed_type IN ('rss', 'atom', 'json')"
    )

    alter table(:feeds) do
      remove :adapter_config
      remove :adapter_cursor
      remove :source_kind
      remove :adapter_id
    end
  end
end
