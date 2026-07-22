defmodule Earss.Repo.Migrations.AddFeverApiKeyToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Precomputed Fever api_key = md5(username || ":" || secret) hex lowercase.
      # Secret is the login password at set time, or a dedicated app password.
      add :fever_api_key, :text
    end

    create unique_index(:users, [:fever_api_key],
      where: "fever_api_key IS NOT NULL",
      name: :users_fever_api_key_index
    )
  end
end
