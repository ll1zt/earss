defmodule Earss.Repo.Migrations.AddReturnOriginalToFeeds do
  @moduledoc """
  Goal 2: feed-level translation may optionally append the original text
  after the translation (admin opt-in, default off). Subscription-level
  overrides keep their own `return_original` (default on).
  """
  use Ecto.Migration

  def up do
    alter table(:feeds) do
      add :return_original, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:feeds) do
      remove :return_original
    end
  end
end
