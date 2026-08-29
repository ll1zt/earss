defmodule Earss.Repo.Migrations.AddSynthesisFieldsToTtsRequests do
  use Ecto.Migration

  # The synthesis pipeline (Earss.TTS.Worker) consumes `requested` rows and
  # moves them through processing → ready | failed, storing the produced
  # audio on disk and its metadata on the row.
  def change do
    alter table(:tts_requests) do
      add :lang, :string
      add :provider, :string
      add :provider_job_id, :string
      add :audio_path, :string
      add :audio_bytes, :bigint
      add :audio_duration_secs, :integer
      add :error, :text
      add :attempt_count, :integer, null: false, default: 0
      add :retry_at, :utc_datetime
    end

    # Worker scan: requested rows that are due (retry_at passed or never set).
    create index(:tts_requests, [:state, :retry_at])
  end
end
