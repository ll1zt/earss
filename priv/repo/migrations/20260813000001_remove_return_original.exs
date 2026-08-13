defmodule Earss.Repo.Migrations.RemoveReturnOriginal do
  @moduledoc """
  Goal 2 cleanup: drop the `return_original` booleans superseded by the
  `original_layout` enum (migration 20260801000003).

  The layout enum (off / inline / section / interleaved) replaced the
  boolean on both `feeds` and `subscriptions`; the columns were kept only
  for rollback compatibility and nothing reads them anymore — the admin
  translate page even displayed a value with no effect on output.
  """
  use Ecto.Migration

  def up do
    alter table(:subscriptions) do
      remove :return_original
    end

    alter table(:feeds) do
      remove :return_original
    end
  end

  def down do
    alter table(:feeds) do
      add :return_original, :boolean, null: false, default: false
    end

    alter table(:subscriptions) do
      add :return_original, :boolean, null: false, default: true
    end
  end
end
