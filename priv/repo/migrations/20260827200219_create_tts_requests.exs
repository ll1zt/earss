defmodule Earss.Repo.Migrations.CreateTtsRequests do
  use Ecto.Migration

  # Goal: "listen to this article" intent capture (docs/tts_plan.md successor).
  # One row per starred-for-listening entry; idempotent on entry_id. The
  # synthesis pipeline consumes `requested` rows and moves them through its
  # own states later.
  def change do
    create table(:tts_requests) do
      add :state, :string, null: false, default: "requested"

      add :entry_id, references(:entries, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tts_requests, [:entry_id])
    create index(:tts_requests, [:state])
  end
end
