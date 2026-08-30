defmodule Earss.Repo.Migrations.AddPgroongaSearchIndex do
  @moduledoc """
  Full-text search index for `entries`, using PGroonga when available
  (docs/mcp-design.md §4.1, milestone M3).

  PGroonga is an optional dependency: its default `TokenBigram` tokenizer
  makes Chinese, Japanese and English searchable in the same column, which
  Postgres's built-in FTS cannot do — but the extension package is not
  installed on every deployment (CI, a plain docker compose stack).

  The migration only creates the extension and index when the package is
  present in `pg_available_extensions`. On hosts without it, nothing is
  created and `mix ecto.migrate` still succeeds; the MCP search tool then
  degrades to ILIKE and reports `search_mode: "ilike"`.

  Because availability is a property of the Postgres host, not of the code,
  a single migration would break on every host that lacks the package. The
  guard is what keeps this deployable everywhere.
  """

  use Ecto.Migration

  @extension "pgroonga"

  def up do
    if pgroonga_available?() do
      execute "CREATE EXTENSION IF NOT EXISTS #{@extension}",
              "DROP EXTENSION IF EXISTS #{@extension}"

      # Default TokenBigram tokenizer needs no WITH clause — its whole point
      # is that CJK and Latin search together out of the box.
      execute """
      CREATE INDEX IF NOT EXISTS entries_search_idx ON entries
        USING pgroonga (title, content, summary)
      """
    end
  end

  def down do
    if pgroonga_available?() do
      execute "DROP INDEX IF EXISTS entries_search_idx"
      execute "DROP EXTENSION IF EXISTS #{@extension}",
              "CREATE EXTENSION IF NOT EXISTS #{@extension}"
    end
  end

  defp pgroonga_available? do
    # Ecto.Adapters.SQL.query/4 is available inside migrations (the repo is
    # pinned at migrate time); the probe asks whether the package exists on
    # this Postgres host.
    case Ecto.Adapters.SQL.query(Earss.Repo, """
         SELECT count(*) FROM pg_available_extensions WHERE name = '#{@extension}'
         """) do
      {:ok, %{rows: [[n]]}} when n > 0 -> true
      _ -> false
    end
  end
end
