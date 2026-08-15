defmodule Earss.Admin.Batch do
  @moduledoc """
  Shared batch-action plumbing for admin tables (subscriptions, feeds,
  categories, translate).

  The four batch controllers re-implemented id parsing, result counting and
  flash phrasing; this module keeps one copy. Controllers still own their
  per-action dispatch (`do_batch_action`-style functions); the table hint in
  each index view reads `limit/0`.
  """

  @limit 50

  @doc "Max ids per batch action (mirrored in the index view hints)."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  Parse `ids[]` from the request body: integers only, uniqed, capped at
  `limit/0`. Handles both the `ids` and `ids[]` form keys.
  """
  @spec ids(Plug.Conn.t()) :: [pos_integer()]
  def ids(conn) do
    raw =
      case conn.body_params do
        %{"ids" => ids} -> ids
        %{"ids[]" => ids} -> ids
        _ -> []
      end

    raw
    |> List.wrap()
    |> Enum.map(&Earss.Admin.Helpers.parse_int/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@limit)
  end

  @doc """
  Run `fun` per item and reduce to `{ok_n, fail_n, notes}`.

  `fun` returns `:ok` / `{:ok, _}` (counted ok) or `{:error, reason}`
  (counted failed; `note_fn` labels the row and `reason` is rendered with
  `Earss.Admin.Helpers.format_error/1`).
  """
  @spec run(
          [item],
          (item -> String.t()),
          (item -> :ok | {:ok, term()} | {:error, term()})
        ) :: {non_neg_integer(), non_neg_integer(), [String.t()]}
        when item: term()
  def run(items, note_fn, fun) do
    Enum.reduce(items, {0, 0, []}, fn item, {ok_n, fail_n, notes} ->
      case fun.(item) do
        :ok ->
          {ok_n + 1, fail_n, notes}

        {:ok, _} ->
          {ok_n + 1, fail_n, notes}

        {:error, reason} ->
          note = "#{note_fn.(item)}: #{Earss.Admin.Helpers.format_error(reason)}"
          {ok_n, fail_n + 1, [note | notes]}
      end
    end)
    |> then(fn {ok_n, fail_n, notes} -> {ok_n, fail_n, Enum.reverse(notes)} end)
  end

  @doc "Uniform batch result flash message (first 3 failure notes)."
  @spec message(String.t(), non_neg_integer(), non_neg_integer(), [String.t()]) :: String.t()
  def message(action, ok_n, fail_n, notes) do
    "Batch #{action}: #{ok_n} ok, #{fail_n} failed" <>
      if(notes == [], do: "", else: " — " <> Enum.join(Enum.take(notes, 3), "; "))
  end

  @doc "Flash type for a batch result (err only when everything failed)."
  @spec flash_type(non_neg_integer(), non_neg_integer()) :: :ok | :err
  def flash_type(ok_n, fail_n), do: if(fail_n > 0 and ok_n == 0, do: :err, else: :ok)
end
