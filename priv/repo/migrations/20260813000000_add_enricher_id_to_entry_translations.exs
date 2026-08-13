defmodule Earss.Repo.Migrations.AddEnricherIdToEntryTranslations do
  @moduledoc """
  Goal 2: record which enricher plugin produced a translation.

  `entry_translations.model` stores the provider/LLM model string (e.g.
  `gpt-4o-mini`), which is not a registry key — `Earss.API.Translation`
  needs the plugin id (e.g. `openai`) to ask the producing plugin for block
  structure (interleaved layout). Without it, interleaved always degraded to
  the section layout.

  Existing rows are left NULL (their producing plugin cannot be recovered);
  the splitter falls back to the section layout for them, as before.
  """
  use Ecto.Migration

  def up do
    alter table(:entry_translations) do
      add :enricher_id, :text
    end

    create index(:entry_translations, [:enricher_id])
  end

  def down do
    drop_if_exists index(:entry_translations, [:enricher_id])
    alter table(:entry_translations) do
      remove :enricher_id
    end
  end
end
