defmodule Earss.Repo.Migrations.AddTranslationPausedToEntries do
  @moduledoc """
  Goal 2: entries whose translation kept failing (>= max_pending_retries) are
  **paused** instead of auto-publishing the original. A paused entry stays
  pending (hidden from protocol clients) until an admin either re-translates
  it (clears the pause + retry count) or publishes the original (clears the
  pending flag).
  """
  use Ecto.Migration

  def up do
    alter table(:entries) do
      add :translation_paused_at, :utc_datetime
    end

    create index(:entries, [:feed_id, :translation_paused_at])
  end

  def down do
    alter table(:entries) do
      remove :translation_paused_at
    end
  end
end
