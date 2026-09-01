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

  Both paths return the same row shape — `%{entry: entry, rank: rank,
  is_read: boolean, is_star: boolean}` — so the tool layer does not branch
  on the backend.

  The fallback is deliberate rather than a stopgap. Search is a core agent
  capability; making it fail outright wherever PGroonga is missing would mean
  the tool is unusable for most operators. Callers get told which mode
  produced the result so the difference in ranking is not a surprise.

  ## Testing both paths

  The backend is chosen by what the Postgres host happens to have installed,
  which means a development or CI database with PGroonga never executes the
  ILIKE path — and a host without it never executes the ranked path. Both
  have had bugs that the other path's tests could not see, so the choice can
  be pinned for a single call with `:mode`:

      Search.search("term", mode: :ilike)

  `mode/0` still reports the real backend; the option only overrides the
  implementation for that one call.

  Installing PGroonga (NixOS):

      services.postgresql.extensions = [pkgs.postgresql18Packages.pgroonga];

  then `CREATE EXTENSION pgroonga` and the index from the migration in
  docs/mcp-design.md §4.1.
  """

  import Ecto.Query, warn: false

  alias Earss.Feeds.Entry
  alias Earss.Reader.EntryState
  alias Earss.Repo

  @doc """
  Search `entries` by keyword.

  Returns `{:ok, rows}` where each row is `%{entry: entry, rank: rank,
  is_read: boolean, is_star: boolean}`, newest first within the same rank.
  `opts` accepts `:limit`, `:offset`, `:feed_id` and `:mode`.

  Read state is joined rather than defaulted: an agent triages search
  results the same way it triages the timeline, and a row that always says
  "unread" would make it re-process articles the operator already read.
  No row means unread and unstarred (decision D2), hence the `coalesce`.

  `:mode` forces `:pgroonga` or `:ilike` for this call. It exists so tests
  can exercise the backend the host does not have — see the moduledoc.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]}
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20) |> max(1) |> min(100)
    offset = Keyword.get(opts, :offset, 0) |> max(0)
    feed_id = Keyword.get(opts, :feed_id)

    query = String.trim(query)

    if query == "" do
      {:ok, []}
    else
      # Filtering in SQL rather than after the fact: a feed_id applied to the
      # already-truncated result set would silently drop matches and
      # under-report the count.
      {:ok, run(mode(opts), feed_id, query, limit, offset, opts)}
    end
  end

  defp run(:pgroonga, feed_id, term, limit, offset, opts),
    do: pgroonga_search(feed_id, term, limit, offset, opts)

  defp run(:ilike, feed_id, term, limit, offset, _opts),
    do: ilike_search(feed_id, term, limit, offset)

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

  # An explicit `:mode` opt wins, so a test can pin the backend the host does
  # not have. Anything unrecognised falls back to detecting it.
  defp mode(opts) do
    case Keyword.get(opts, :mode) do
      :pgroonga -> :pgroonga
      :ilike -> :ilike
      _ -> mode()
    end
  end

  ## PGroonga path

  defp pgroonga_search(feed_id, term, limit, offset, opts) do
    # &@~ is PGroonga's full-text match; pgroonga_score needs the tableoid
    # and ctid of the matched row to look the score up.
    #
    # The ranking lives in SQL: rank first, then newest first, with entries
    # that have no publication date last (NULLS LAST). Re-sorting in Elixir
    # is what previously inverted that last rule.
    sql = """
    SELECT e.id, pgroonga_score(e.tableoid, e.ctid) AS rank
    FROM entries AS e
    WHERE (e.title &@~ $1 OR e.content &@~ $1 OR e.summary &@~ $1)
      AND ($4::bigint IS NULL OR e.feed_id = $4)
    ORDER BY rank DESC, e.published_at DESC NULLS LAST, e.id DESC
    LIMIT $2 OFFSET $3
    """

    case Repo.query(sql, [term, limit, offset, feed_id]) do
      {:ok, %{rows: []}} ->
        []

      {:ok, result} ->
        result.rows
        |> Enum.with_index()
        |> Map.new(fn {[id, rank], position} -> {id, {rank, position}} end)
        |> hydrate()

      {:error, _reason} ->
        # The extension exists but the index or column is missing (partially
        # migrated). Degrade instead of failing the agent's search.
        # A forced :pgroonga (tests) must not silently become ILIKE — that
        # would make a broken ranked query look like a passing one.
        if Keyword.get(opts, :mode) == :pgroonga do
          raise "pgroonga search failed: #{inspect(term)}"
        else
          ilike_search(feed_id, term, limit, offset)
        end
    end
  end

  ## ILIKE path

  defp ilike_search(feed_id, term, limit, offset) do
    pattern = "%#{escape_like(term)}%"

    Entry
    |> join(:left, [e], st in EntryState, on: st.entry_id == e.id)
    |> where(
      [e, st],
      ilike(e.title, ^pattern) or ilike(e.content, ^pattern) or ilike(e.summary, ^pattern)
    )
    |> maybe_feed(feed_id)
    |> order_by([e], desc_nulls_last: e.published_at, desc: e.id)
    |> limit(^limit)
    |> offset(^offset)
    |> select_state()
    |> Repo.all()
    |> Enum.map(fn {entry, is_read, is_star} ->
      %{entry: entry, rank: 0.0, is_read: is_read, is_star: is_star}
    end)
  end

  # Composed rather than `is_nil(^feed_id) or e.feed_id == ^feed_id`: Ecto
  # rejects comparing a pinned value to nil as unsafe, and a branch that can
  # never be true reads as if the filter were applied when it is not.
  defp maybe_feed(query, nil), do: query
  defp maybe_feed(query, feed_id), do: where(query, [e], e.feed_id == ^feed_id)

  ## Shared

  # Read/starred state, inlined so an agent does not need a follow-up call
  # per result. Rows are created lazily (decision D2): no row means unread
  # and unstarred, so the missing side of the join coalesces to false.
  defp select_state(query) do
    select(query, [e, st], {
      e,
      fragment("coalesce(?, false)", st.is_read),
      fragment("coalesce(?, false)", st.is_star)
    })
  end

  # The PGroonga path returns ids, so the entries themselves are loaded in a
  # second query. `WHERE id IN (...)` does not preserve the order the ids
  # came back in, and a map is not order-preserving either, so each id keeps
  # the position it had in the ranked result and the rows are restored to
  # that order — the SQL ordering is the single source of truth.
  defp hydrate(rows_by_id) when map_size(rows_by_id) == 0, do: []

  defp hydrate(rows_by_id) do
    ids = Map.keys(rows_by_id)

    Entry
    |> join(:left, [e], st in EntryState, on: st.entry_id == e.id)
    |> where([e], e.id in ^ids)
    |> select_state()
    |> Repo.all()
    |> Enum.map(fn {entry, is_read, is_star} ->
      {rank, position} = Map.fetch!(rows_by_id, entry.id)

      %{entry: entry, rank: rank || 0.0, is_read: is_read, is_star: is_star, position: position}
    end)
    |> Enum.sort_by(& &1.position)
    |> Enum.map(&Map.delete(&1, :position))
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
