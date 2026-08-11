defmodule Earss.Repo.Migrations.AddOriginalLayout do
  @moduledoc """
  Goal 2: replace the boolean `return_original` with a layout enum so
  concatenated output can be styled differently.

  Layouts: `off` (translation only), `inline` (translation + <hr> + original,
  the old return_original=true), `section` (translation + <hr> + a wrapped
  original section), `interleaved` (paragraph-by-paragraph alternation).

  Feed-level defaults to `off` (matching the old return_original=false);
  subscription-level defaults to `inline` (matching the old default true).
  The `return_original` columns are kept (unused) for rollback compatibility.
  """
  use Ecto.Migration

  def up do
    alter table(:subscriptions) do
      add :original_layout, :text, null: false, default: "inline"
    end

    alter table(:feeds) do
      add :original_layout, :text, null: false, default: "off"
    end
  end

  def down do
    alter table(:feeds) do
      remove :original_layout
    end

    alter table(:subscriptions) do
      remove :original_layout
    end
  end
end
