defmodule Earss.TTS do
  @moduledoc """
  DB-facing context for the TTS / listen-later pipeline.

  This goal only captures **intent**: a reader clicks the injected listen
  control (see `Earss.API.ListenControls`) and `record_request/1` upserts an
  idempotent `Earss.TTS.Request` row. The synthesis provider, worker and
  audio storage arrive in later goals on this branch — they will consume
  `requested` rows, so the intent survives restarts and is queryable from
  the admin console.
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
        %Request{}
        |> Request.changeset(%{entry_id: entry_id})
        |> Repo.insert()
        |> case do
          {:ok, request} ->
            {:ok, request}

          # Lost a race with a concurrent insert for the same entry —
          # re-read so the caller always gets the canonical row back.
          {:error, _changeset} ->
            existing = Repo.get_by(Request, entry_id: entry_id)
            if existing, do: {:ok, existing}, else: {:error, :unknown_entry}
        end
    end
  end

  def record_request(_), do: {:error, :unknown_entry}

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
end
