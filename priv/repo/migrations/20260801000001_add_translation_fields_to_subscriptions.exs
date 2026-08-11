defmodule Earss.Repo.Migrations.AddTranslationFieldsToSubscriptions do
  @moduledoc """
  Additive per-subscription translation overrides (Goal 2, docs/translate.md).

  `translate_to` NULL = follow the feed's configuration; a value enables
  translation for this user/subscription only. `return_original` controls
  whether the protocol layer appends the original text after the translation.
  """
  use Ecto.Migration

  def up do
    alter table(:subscriptions) do
      add :translate_to, :text
      add :return_original, :boolean, null: false, default: true
    end
  end

  def down do
    alter table(:subscriptions) do
      remove :return_original
      remove :translate_to
    end
  end
end
