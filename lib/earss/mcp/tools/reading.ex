defmodule Earss.MCP.Tools.Reading do
  @moduledoc """
  Query and read-state tools: the surface an agent uses to find and triage
  articles.

  All reads go through `Earss.Reader` and `Earss.Feeds`; nothing here touches
  `Repo`. Filters mirror what the operator has in the admin timeline, so an
  agent sees the same library the operator does — including the rule that
  entries still inside the translation window stay hidden until the
  translation lands.
  """

  alias Earss.Feeds
  alias Earss.MCP.Search
  alias Earss.MCP.Tool
  alias Earss.MCP.Views
  alias Earss.Reader

  @max_limit 100

  @doc """
  Every tool this module contributes.
  """
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new(
        name: "entry_list",
        description:
          "List articles from your subscriptions, newest first. Returns " <>
            "excerpts (not full bodies) with read/starred state inlined — call " <>
            "entry_get for the full text of a specific article. Supports " <>
            "filtering by feed, category, read state, starred, and time range.",
        input_schema: entry_list_schema(),
        mutating: false,
        handler: &entry_list/1
      ),
      Tool.new(
        name: "entry_search",
        description:
          "Keyword search across every stored article's title, summary and " <>
            "body. Works for English, Chinese and Japanese. Returns excerpts " <>
            "with read/starred state, ranked by relevance when the PGroonga " <>
            "extension is installed (search_mode says which).",
        input_schema: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Keywords to search for"},
            limit: %{type: "integer", description: "Max results (default 20, max 100)"},
            offset: %{type: "integer", description: "Results to skip (default 0)"},
            feed_id: %{type: "integer", description: "Restrict to one feed"}
          },
          required: ["query"],
          additionalProperties: false
        },
        mutating: false,
        handler: &entry_search/1
      ),
      Tool.new(
        name: "entry_get",
        description:
          "Get one article in full: title, author, link, publication date and " <>
            "the complete body text. Use this after entry_list to read an " <>
            "article you are interested in.",
        input_schema: %{
          type: "object",
          properties: %{
            id: %{type: "integer", description: "Entry id (from entry_list)"}
          },
          required: ["id"],
          additionalProperties: false
        },
        mutating: false,
        handler: &entry_get/1
      ),
      Tool.new(
        name: "feed_list",
        description:
          "List your subscriptions with unread counts and feed health " <>
            "(errors, last fetch, next fetch, translation target).",
        input_schema: %{
          type: "object",
          properties: %{
            include_hidden: %{
              type: "boolean",
              description: "Include hidden subscriptions (default false)"
            }
          },
          additionalProperties: false
        },
        mutating: false,
        handler: &feed_list/1
      ),
      Tool.new(
        name: "entry_mark_read",
        description: "Mark one article as read.",
        input_schema: entry_id_schema("Mark as read"),
        mutating: true,
        handler: &entry_mark_read/1
      ),
      Tool.new(
        name: "entry_mark_unread",
        description: "Mark one article as unread.",
        input_schema: entry_id_schema("Mark as unread"),
        mutating: true,
        handler: &entry_mark_unread/1
      ),
      Tool.new(
        name: "entry_star",
        description: "Star one article.",
        input_schema: entry_id_schema("Star"),
        mutating: true,
        handler: &entry_star/1
      ),
      Tool.new(
        name: "entry_unstar",
        description: "Remove the star from one article.",
        input_schema: entry_id_schema("Unstar"),
        mutating: true,
        handler: &entry_unstar/1
      )
    ]
  end

  ## Handlers

  defp entry_list(args) do
    opts = [
      limit: clamp_limit(args["limit"]),
      offset: max(Map.get(args, "offset") || 0, 0),
      include_hidden: Map.get(args, "include_hidden") == true,
      unread_only: Map.get(args, "unread_only") == true,
      starred_only: Map.get(args, "starred_only") == true
    ]

    opts = put_if_present(opts, :feed_id, args["feed_id"])
    opts = put_if_present(opts, :category_id, normalize_category(args["category_id"]))

    rows = Reader.list_entries(opts)

    entries = Enum.map(rows, &Views.entry_summary(&1, excerpt_chars: args["excerpt_chars"]))

    {:ok, %{entries: entries, count: length(entries)}}
  end

  # `:mode` is a test-only escape hatch, not part of the advertised schema:
  # pinning the backend is how a suite exercises the path the host does not
  # have installed (see Earss.MCP.Search). It is accepted here so the tool
  # layer is what gets tested, not just the query module.
  @test_modes %{"pgroonga" => :pgroonga, "ilike" => :ilike}

  defp entry_search(%{"query" => query} = args) when is_binary(query) do
    opts = [
      limit: clamp_limit(args["limit"]),
      offset: args["offset"] || 0,
      feed_id: args["feed_id"]
    ]

    opts =
      case Map.get(@test_modes, args["mode"]) do
        nil -> opts
        mode -> Keyword.put(opts, :mode, mode)
      end

    {:ok, rows} = Search.search(query, opts)

    entries = Enum.map(rows, &Views.entry_summary(&1, excerpt_chars: args["excerpt_chars"]))

    {:ok,
     %{
       entries: entries,
       count: length(entries),
       query: query,
       search_mode: Search.mode(),
       ranked: Search.mode() == :pgroonga
     }}
  end

  defp entry_search(_), do: {:error, "query is required and must be a string"}

  defp entry_get(%{"id" => id}) when is_integer(id) do
    case Feeds.get_entry(id) do
      nil -> {:error, :not_found}
      entry -> {:ok, Views.entry_detail(entry)}
    end
  end

  defp entry_get(_), do: {:error, :invalid_id}

  defp feed_list(args) do
    subs =
      Reader.list_subscriptions(
        include_hidden: Map.get(args, "include_hidden") == true,
        with_unread_count: true
      )

    {:ok, %{subscriptions: Enum.map(subs, &Views.subscription_summary/1)}}
  end

  defp entry_mark_read(%{"id" => id}) when is_integer(id), do: mark(id, &Reader.mark_read/1)
  defp entry_mark_read(_), do: {:error, :invalid_id}

  defp entry_mark_unread(%{"id" => id}) when is_integer(id), do: mark(id, &Reader.mark_unread/1)
  defp entry_mark_unread(_), do: {:error, :invalid_id}

  defp entry_star(%{"id" => id}) when is_integer(id), do: mark(id, &Reader.set_star(&1, true))
  defp entry_star(_), do: {:error, :invalid_id}

  defp entry_unstar(%{"id" => id}) when is_integer(id), do: mark(id, &Reader.set_star(&1, false))
  defp entry_unstar(_), do: {:error, :invalid_id}

  defp mark(id, fun) do
    case fun.(id) do
      {:ok, _state} -> {:ok, %{id: id, ok: true}}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Argument plumbing

  # The timeline takes :none for "uncategorized", so pass it through; a
  # missing key must mean "no filter", not "filter by nil".
  defp normalize_category("none"), do: :none
  defp normalize_category(nil), do: nil
  defp normalize_category(other), do: other

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp clamp_limit(nil), do: 20

  defp clamp_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_limit)

  defp clamp_limit(_), do: 20

  defp entry_id_schema(verb) do
    %{
      type: "object",
      properties: %{id: %{type: "integer", description: "#{verb} this entry"}},
      required: ["id"],
      additionalProperties: false
    }
  end

  defp entry_list_schema do
    %{
      type: "object",
      properties: %{
        limit: %{
          type: "integer",
          description: "Max entries to return (default 20, max #{@max_limit})"
        },
        offset: %{type: "integer", description: "Entries to skip (default 0)"},
        feed_id: %{type: "integer", description: "Only this feed"},
        category_id: %{
          description: "Only this category, or the string \"none\" for uncategorized"
        },
        unread_only: %{type: "boolean", description: "Only unread entries"},
        starred_only: %{type: "boolean", description: "Only starred entries"},
        include_hidden: %{type: "boolean", description: "Include hidden subscriptions"},
        excerpt_chars: %{type: "integer", description: "Excerpt length (default 500)"}
      },
      additionalProperties: false
    }
  end
end
