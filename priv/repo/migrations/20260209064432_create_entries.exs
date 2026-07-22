defmodule Earss.Repo.Migrations.CreateEntries do
  @moduledoc """
  创建 entries 表（Feed 条目，全局共享）。

  见 docs/data_model.md、docs/data_lifecycle.md
  """
  use Ecto.Migration

  def change do
    create table(:entries) do
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :link, :text, null: false
      add :guid, :text, null: false
      add :title, :text
      add :author, :text
      add :summary, :text
      add :content, :text
      add :published_at, :utc_datetime
      add :content_hash, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:entries, [:feed_id, :guid])
    create index(:entries, [:feed_id, :published_at])
    create index(:entries, [:published_at])
    create index(:entries, [:inserted_at])
  end
end
