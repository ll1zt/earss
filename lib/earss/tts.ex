defmodule Earss.TTS do
  @moduledoc """
  DB-facing context for the TTS / listen-later pipeline.

  Intent capture (`record_request/1`) is invoked by the listen endpoint when
  a reader clicks the injected control (see `Earss.API.ListenControls`);
  `Earss.TTS.Worker` consumes `requested` rows and moves them through
  `processing` to `ready` / `failed`. `Earss.TTS.Podcast` renders `ready`
  rows as an Apple-Podcasts-compatible feed. The admin functions
  (`stats/0`, `list_requests_recent/1`, `requeue/1`, `delete_request/1`)
  back the `/admin/tts` page.
  """

  alias Earss.Repo
  alias Earss.TTS.Request

  import Ecto.Query, warn: false

  @doc """
  Record that the entry should be turned into audio. Idempotent: an existing
  request for the entry is returned unchanged.

  Returns `{:ok, %Request{}}`, or `{:error, :unknown_entry}` when no such
  entry exists (the click page turns this into a 404).
  """
  @spec record_request(pos_integer()) :: {:ok, Request.t()} | {:error, :unknown_entry}
  def record_request(entry_id) when is_integer(entry_id) and entry_id > 0 do
    case Repo.get_by(Request, entry_id: entry_id) do
      %Request{} = existing ->
        {:ok, existing}

      nil ->
        insert_request(entry_id)
    end
  end

  def record_request(_), do: {:error, :unknown_entry}

  defp insert_request(entry_id) do
    result =
      %Request{}
      |> Request.changeset(%{entry_id: entry_id})
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: :entry_id,
        returning: true
      )

    case result do
      {:ok, %Request{} = request} ->
        {:ok, request}

      # Lost a race with a concurrent insert for the same entry: the unique
      # index swallowed our row, so re-read to hand back the canonical one.
      # A row that vanished between the two is a deleted entry.
      {:ok, nil} ->
        case Repo.get_by(Request, entry_id: entry_id) do
          %Request{} = existing -> {:ok, existing}
          nil -> {:error, :unknown_entry}
        end

      {:error, _changeset} ->
        {:error, :unknown_entry}
    end
  end

  @doc "List requests in insertion order (admin console)."
  @spec list_requests(keyword()) :: [Request.t()]
  def list_requests(opts \\ []) do
    state = Keyword.get(opts, :state)

    Request
    |> maybe_where_state(state)
    |> order_by(asc: :id)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> Repo.all()
  end

  defp maybe_where_state(query, nil), do: query
  defp maybe_where_state(query, state), do: where(query, [r], r.state == ^state)

  @doc """
  Queue stats for the admin page: one grouped query, plus the total bytes
  of ready audio. Orphaned files (no row) are not counted — only the
  retention sweep sees those.
  """
  @spec stats() :: %{
          ready: non_neg_integer(),
          requested: non_neg_integer(),
          processing: non_neg_integer(),
          failed: non_neg_integer(),
          audio_bytes: non_neg_integer()
        }
  def stats do
    counts =
      from(r in Request,
        group_by: r.state,
        select: {r.state, count(r.id)}
      )
      |> Repo.all()
      |> Map.new()

    audio_bytes =
      from(r in Request, where: r.state == :ready, select: coalesce(sum(r.audio_bytes), 0))
      |> Repo.one()
      |> bytes_to_integer()

    %{
      ready: Map.get(counts, :ready, 0),
      requested: Map.get(counts, :requested, 0),
      processing: Map.get(counts, :processing, 0),
      failed: Map.get(counts, :failed, 0),
      audio_bytes: audio_bytes
    }
  end

  # sum(bigint) returns a Decimal on postgrex — normalize for the callers.
  defp bytes_to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp bytes_to_integer(n) when is_integer(n), do: n

  @doc """
  Requests for the admin table, most recent activity first. Same default
  limit as `list_requests/1` (200 — no pagination; single-operator scale).

  Options: `:state` (filter), `:preload_entry` (attach `entry` for title and
  original-link rendering).
  """
  @spec list_requests_recent(keyword()) :: [Request.t()]
  def list_requests_recent(opts \\ []) do
    state = Keyword.get(opts, :state)

    Request
    |> maybe_where_state(state)
    |> order_by(desc: :updated_at, desc: :id)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> maybe_preload_entry(Keyword.get(opts, :preload_entry, false))
    |> Repo.all()
  end

  defp maybe_preload_entry(query, true), do: preload(query, [:entry])
  defp maybe_preload_entry(query, false), do: query

  @doc """
  Reset a request so the worker picks it up again: `requested`, backoff
  cleared, attempt count zeroed, error wiped.

  Only `requested` and `failed` rows can be requeued — `processing` is a
  task the worker owns (requeueing under it would race the completion
  update) and `ready` needs no retry.
  """
  @spec requeue(pos_integer()) ::
          {:ok, Request.t()} | {:error, :not_found} | {:error, :invalid_state}
  def requeue(id) when is_integer(id) and id > 0 do
    case Repo.get(Request, id) do
      nil ->
        {:error, :not_found}

      %Request{state: state} = request when state in [:requested, :failed] ->
        request
        |> Ecto.Changeset.change(
          state: :requested,
          retry_at: nil,
          attempt_count: 0,
          error: nil
        )
        |> Repo.update()

      %Request{} ->
        {:error, :invalid_state}
    end
  end

  def requeue(_), do: {:error, :not_found}

  @doc """
  One TTS request by id, or `nil`.

  A single-row lookup for callers that know the id (the MCP impact report
  for `tts_delete`); the listing functions are for the admin tables.
  """
  @spec get_request(pos_integer()) :: Request.t() | nil
  def get_request(id) when is_integer(id) and id > 0, do: Repo.get(Request, id)
  def get_request(_), do: nil

  @doc """
  Delete a request row and, when the row owns a file, the audio file too.
  `processing` rows are rejected — the worker's task still holds them and
  its completion update would race the delete.

  Returns `{:ok, %{row: boolean(), file: boolean()}}` (`file: false` when
  the row had no audio or the file was already gone) so the admin flash can
  report partial cleanup. File deletion is best-effort: the retention
  orphan sweep collects leftovers.
  """
  @spec delete_request(pos_integer()) ::
          {:ok, %{row: boolean(), file: boolean()}}
          | {:error, :not_found}
          | {:error, :invalid_state}
  def delete_request(id) when is_integer(id) and id > 0 do
    case Repo.get(Request, id) do
      nil ->
        {:error, :not_found}

      %Request{state: :processing} ->
        {:error, :invalid_state}

      %Request{audio_path: audio_path} = request ->
        file_deleted? = audio_path != nil and delete_audio_file(request)

        case Repo.delete(request) do
          {:ok, _} -> {:ok, %{row: true, file: file_deleted?}}
          {:error, _} -> {:error, :invalid_state}
        end
    end
  end

  def delete_request(_), do: {:error, :not_found}

  defp delete_audio_file(%Request{audio_path: audio_path}) when is_binary(audio_path) do
    case tts_audio_dir() do
      dir when is_binary(dir) ->
        case File.rm(Path.join(dir, audio_path)) do
          :ok ->
            true

          {:error, :enoent} ->
            false

          {:error, reason} ->
            require Logger

            Logger.warning(
              "Earss.TTS.delete_request: could not delete #{audio_path}: #{inspect(reason)}"
            )

            false
        end

      _ ->
        false
    end
  end

  defp tts_audio_dir do
    case Application.get_env(:earss, :tts) do
      kw when is_list(kw) -> Keyword.get(kw, :audio_dir)
      _ -> nil
    end
  end

  @doc """
  True when TTS is configured at all: a registered provider, an enabled
  worker, or any existing request row. Drives the admin nav entry and the
  `/admin/tts` 404 behaviour.
  """
  @spec configured?() :: boolean()
  def configured? do
    provider? = Earss.TTS.Registry.list_providers() != []

    worker? =
      :earss
      |> Application.get_env(:tts, [])
      |> Keyword.get(:worker, [])
      |> Keyword.get(:enabled, false)

    provider? or worker? or Repo.exists?(Request)
  end
end
