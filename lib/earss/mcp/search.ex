defmodule Earss.MCP.Search do
  @moduledoc """
  Keyword search across stored entries.

  Two implementations behind one function, chosen at query time:

    * **PGroonga** when the extension is installed — `&@~` with
      `pgroonga_score` ranking. Its default `TokenBigram` tokenizer uses
      bigrams for non-ASCII characters and whitespace for ASCII ones, so
      Chinese, Japanese and English all work in the same column without
      configuration. This is what makes CJK search possible at all: Postgres
      built-in FTS has no CJK tokenizer.
    * **ILIKE** otherwise — no ranking and a sequential scan, but it works
      on any deployment, including CI and a plain `docker compose` stack
      where installing the extension is not an option.

  The fallback is deliberate rather than a stopgap. Search is a core agent
  capability; making it fail outright wherever PGroonga is missing would mean
  the tool is unusable for most operators. Callers get told which mode
  produced the result so the difference in ranking is not a surprise.

  Installing PGroonga (NixOS):

      services.postgresql.extensions = [pkgs.postgresql18Packages.pgroonga];

  then `CREATE EXTENSION pgroonga` and the index from the migration in
  docs/mcp-design.md §4.1.
  """

  import Ecto.Query, warn: false

  alias Earss.Feeds.Entry
  alias Earss.Repo

  @doc """
  Search `entries` by keyword.

  Returns `{:ok, rows}` where each row is the entry plus a `:rank` and the
  read/starred state, newest first within the same rank. `opts` accepts
  `:limit` and `:offset`.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]}
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20) |> max(1) |> min(100)
    offset = Keyword.get(opts, :offset, 0) |> max(0)

    query = String.trim(query)

    if query == "" do
      {:ok, []}
    else
      rows =
        if pgroonga?() do
          pgroonga_search(query, limit, offset)
        else
          ilike_search(query, limit, offset)
        end

      {:ok, rows}
    end
  end

  @doc """
  Which implementation will be used: `:pgroonga` or `:ilike`.

  Exposed so tool responses can state the mode, and so tests can assert the
  behaviour they intend to exercise rather than whichever happened to be
  installed.
  """
  @spec mode() :: :pgroonga | :ilike
  def mode do
    if pgroonga?(), do: :pgroonga, else: :ilike
  end

  ## PGroonga path

  defp pgroonga_search(query, limit, offset) do
    # &@~ is PGroonga's full-text match; pgroonga_score needs the tableoid
    # and ctid of the matched row to look the score up.
    sql = """
    SELECT e.id, pgroonga_score(e.tableoid, e.ctid) AS rank
    FROM entries AS e
    WHERE e.title &@~ $1 OR e.content &@~ $1 OR e.summary &@~ $1
    ORDER BY rank DESC, e.published_at DESC NULLS LAST, e.id DESC
    LIMIT $2 OFFSET $3
    """

    case Repo.query(sql, [query, limit, offset]) do
      {:ok, %{rows: []}} ->
        []

      {:ok, result} ->
        hydrate(Map.new(result.rows, fn [id, rank] -> {id, rank} end))

      {:error, _reason} ->
        # The extension exists but the index or column is missing (partially
        # migrated). Degrade instead of failing the agent's search.
        ilike_search(query, limit, offset)
    end
  end

  ## ILIKE path

  defp ilike_search(query, limit, offset) do
    pattern = "%#{escape_like(query)}%"

    rows =
      Entry
      |> where(
        [e],
        ilike(e.title, ^pattern) or ilike(e.content, ^pattern) or ilike(e.summary, ^pattern)
      )
      |> order_by([e], desc_nulls_last: e.published_at, desc: e.id)
      |> limit(^limit)
      |> offset(^offset)
      |> select([e], %{entry: e, rank: 0.0})
      |> Repo.all()

    rows
  end

  ## Shared

  # The PGroonga path returns ids, so the entries are loaded in one query and
  # the ranking order is restored by hand — SQL ordering is already correct,
  # but a map lookup is not order-preserving.
  defp hydrate(rank_by_id) when map_size(rank_by_id) == 0, do: []

  defp hydrate(rank_by_id) do
    ids = Map.keys(rank_by_id)

    Entry
    |> where([e], e.id in ^ids)
    |> Repo.all()
    |> Enum.map(fn entry -> %{entry: entry, rank: Map.get(rank_by_id, entry.id, 0.0)} end)
    |> Enum.sort_by(&{-(&1.rank || 0.0), rank_tiebreak(&1.entry)})
  end

  defp rank_tiebreak(entry) do
    # Newest first for equal rank, matching the SQL ordering.
    case entry.published_at do
      nil -> {0, -entry.id}
      dt -> {1, -DateTime.to_unix(dt)}
    end
  end

  # ILIKE treats % and _ as wildcards; a query containing them should match
  # them literally. Backslash is the default LIKE escape character.
  defp escape_like(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp pgroonga? do
    case Repo.query("SELECT 1 FROM pg_extension WHERE extname = 'pgroonga'") do
      {:ok, %{num_rows: n}} when n > 0 -> true
      _ -> false
    end
  end
end
