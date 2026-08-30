defmodule Earss.TTS.Request do
  @moduledoc """
  A "listen to this article" request (TTS intent) for one entry, plus the
  synthesis state machine built on top of it.

  One row per entry (unique index); repeated requests converge on the same
  row. `state`:

    * `requested` — created by the listen control / admin, waiting for the
      worker (or due again after a failed attempt, see `retry_at`)
    * `processing` — claimed by `Earss.TTS.Worker`
    * `ready` — audio produced; `audio_path`/`audio_bytes`/
      `audio_duration_secs` filled
    * `failed` — gave up after `max_retries` attempts (`error` explains)

  The audio file lives under the configured `:audio_dir`; the row stores
  only its relative filename.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @states [:requested, :processing, :ready, :failed]

  schema "tts_requests" do
    field :state, Ecto.Enum, values: @states, default: :requested

    field :lang, :string
    field :provider, :string
    field :provider_job_id, :string
    field :audio_path, :string
    field :audio_bytes, :integer
    field :audio_duration_secs, :integer
    field :error, :string
    field :attempt_count, :integer, default: 0
    field :retry_at, :utc_datetime

    belongs_to :entry, Earss.Feeds.Entry

    timestamps(type: :utc_datetime)
  end

  @doc "State values for admin filters and tests."
  @spec states() :: [atom()]
  def states, do: @states

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:entry_id])
    |> validate_required([:entry_id])
    |> assoc_constraint(:entry)
    |> unique_constraint(:entry_id)
  end

  @doc """
  Claim changeset used by the worker (trusted internal data): moves the
  request into `processing` and resets the transient error fields.

  Currently unused — the worker claims via a conditional `update_all` —
  kept as the documented single-row form of the claim transition.
  """
  def claim_changeset(request) do
    change(request, state: :processing, error: nil, provider_job_id: nil)
  end

  @doc """
  Failure changeset: records the error, schedules a retry (or gives up into
  `failed` when `attempt_count` reached the limit).
  """
  def failure_changeset(request, opts) do
    attempt = Map.fetch!(opts, :attempt_count)
    max_retries = Map.fetch!(opts, :max_retries)
    backoff_secs = Map.fetch!(opts, :backoff_secs)
    error = Map.fetch!(opts, :error) |> to_string() |> String.slice(0, 500)

    if attempt >= max_retries do
      change(request, state: :failed, attempt_count: attempt, error: error)
    else
      retry_at =
        DateTime.add(DateTime.utc_now(), backoff_secs, :second) |> DateTime.truncate(:second)

      change(request, state: :requested, attempt_count: attempt, retry_at: retry_at, error: error)
    end
  end
end
