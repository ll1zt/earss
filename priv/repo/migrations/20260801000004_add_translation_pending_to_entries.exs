defmodule Earss.Repo.Migrations.AddTranslationPendingToEntries do
  @moduledoc """
  Goal 2: publish model for translations.

  `entries.translation_pending_at` marks an entry whose translation is still
  being produced (NULL = ready). New entries of translated feeds are flagged
  pending at ingest; the protocol layer hides pending entries so clients only
  ever see the final form (translation or, once translation is disabled,
  original). A periodic worker retries failed pending entries; disabling a
  feed's translation clears its pending flags.
  """
  use Ecto.Migration

  def up do
    alter table(:entries) do
      add :translation_pending_at, :utc_datetime
    end

    create index(:entries, [:translation_pending_at])
  end

  def down do
    drop_if_exists index(:entries, [:translation_pending_at])

    alter table(:entries) do
      remove :translation_pending_at
    end
  end
end
