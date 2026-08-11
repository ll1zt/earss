defmodule Earss.Repo.Migrations.AddTranslationFieldsToFeedsAndEntries do
  @moduledoc """
  Additive translation fields for Goal 2 (docs/translate.md).

  feeds gain the feed-level translation configuration plus a failure counter
  (which never disables a feed — it only surfaces in the admin console);
  `entry_translations` stores one translated copy per (entry, lang), leaving
  the shared `entries` rows untouched.
  """
  use Ecto.Migration

  def up do
    alter table(:feeds) do
      add :translate_to, :text
      add :translate_from, :text
      add :translate_error_count, :integer, null: false, default: 0
    end

    create table(:entry_translations) do
      add :entry_id, references(:entries, on_delete: :delete_all), null: false
      add :lang, :text, null: false
      add :title, :text
      add :summary, :text
      add :content, :text
      add :original_hash, :text
      add :model, :text
      add :translated_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:entry_translations, [:entry_id, :lang])
    create index(:entry_translations, [:lang])
  end

  def down do
    drop_if_exists index(:entry_translations, [:lang])
    drop_if_exists index(:entry_translations, [:entry_id, :lang])
    drop table(:entry_translations)

    alter table(:feeds) do
      remove :translate_error_count
      remove :translate_from
      remove :translate_to
    end
  end
end
