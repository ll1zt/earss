defmodule Earss.Repo.Migrations.AddTranslationRetryCountToEntries do
  @moduledoc """
  Goal 2: failed translation attempts are counted on the entry. After
  `max_pending_retries` (default 5) consecutive failures the translation is
  given up: the pending flag is cleared and the original text is published so
  the article is never hidden forever.
  """
  use Ecto.Migration

  def up do
    alter table(:entries) do
      add :translation_retry_count, :integer, null: false, default: 0
    end
  end

  def down do
    alter table(:entries) do
      remove :translation_retry_count
    end
  end
end
