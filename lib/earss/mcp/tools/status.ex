defmodule Earss.MCP.Tools.Status do
  @moduledoc """
  Status tools: a read-only view of the system so an agent can reason about
  state before acting.

  `system_status` is the health snapshot — poller and retention activity,
  feed error counts, and what the operator has configured. The rest are
  targeted: translation is a per-feed pending/paused breakdown, TTS is the
  synthesis queue, and `feed_stats` is per-feed counts. All are read-only.

  Aggregations reuse the same queries as the admin pages
  (`Earss.Enrichment.stats_many/1`, `Earss.TTS.stats/0`), so the agent sees
  the same numbers the operator does.
  """

  import Ecto.Query, warn: false

  alias Earss.Enrichment
  alias Earss.FeedScheduler
  alias Earss.Feeds
  alias Earss.MCP.Tool
  alias Earss.Reader
  alias Earss.TTS

  @doc """
  Every tool this module contributes.
  """
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new(
        name: "system_status",
        description:
          "Health snapshot of the whole installation: how many feeds and " <>
            "subscriptions, how many are failing or due for a fetch, the " <>
            "translation and TTS configuration, and recent telemetry " <>
            "(fetch/poller activity) when it is enabled.",
        input_schema: %{
          type: "object",
          properties: %{},
          additionalProperties: false
        },
        mutating: false,
        handler: &system_status/1
      ),
      Tool.new(
        name: "feed_stats",
        description:
          "Per-feed counts: entries, unread, and the feed's health fields " <>
            "(errors, last/next fetch). One row per subscribed feed.",
        input_schema: %{
          type: "object",
          properties: %{},
          additionalProperties: false
        },
        mutating: false,
        handler: &feed_stats/1
      ),
      Tool.new(
        name: "translation_status",
        description:
          "Translation pipeline state: which feeds translate, how many " <>
            "entries are still being translated (pending) versus paused " <>
            "awaiting a decision, and error counts.",
        input_schema: %{
          type: "object",
          properties: %{},
          additionalProperties: false
        },
        mutating: false,
        handler: &translation_status/1
      ),
      Tool.new(
        name: "tts_list",
        description:
          "The listen-later / TTS queue: how many requests are pending, " <>
            "processing, ready or failed, and the total audio bytes ready. " <>
            "Pass a state to list individual requests.",
        input_schema: %{
          type: "object",
          properties: %{
            state: %{
              type: "string",
              description: "Filter: requested, processing, ready or failed"
            },
            limit: %{type: "integer", description: "Max requests (default 50)"}
          },
          additionalProperties: false
        },
        mutating: false,
        handler: &tts_list/1
      )
    ]
  end

  ## Handlers

  defp system_status(_args) do
    feeds = Feeds.list_all_feeds()
    subs = Reader.list_subscriptions(include_hidden: true)

    # Same query the system page uses; a container feed can never appear here
    # because list_due_feeds excludes feed_type = "manual".
    due = length(FeedScheduler.list_due_feeds(500))
    errored = Enum.count(feeds, &(&1.error_count > 0))
    disabled = Enum.count(feeds, &(not &1.is_active))

    translating =
      Enum.filter(feeds, &(is_binary(&1.translate_to) and &1.translate_to != ""))
      |> Enum.map(& &1.translate_to)

    {:ok,
     %{
       feeds: length(feeds),
       subscriptions: length(subs),
       due_for_fetch: due,
       with_errors: errored,
       disabled: disabled,
       translating_feeds: length(translating),
       languages: Enum.uniq(translating),
       tts: tts_enabled?(),
       telemetry: Earss.Telemetry.Store.snapshot()
     }}
  end

  defp feed_stats(_args) do
    feeds = Feeds.list_all_feeds()
    unread_by_feed = Reader.unread_counts_by_feed()

    rows =
      Enum.map(feeds, fn feed ->
        %{
          feed_id: feed.id,
          title: feed.title,
          link: feed.link,
          error_count: feed.error_count,
          is_active: feed.is_active,
          last_error: feed.last_error,
          last_fetched_at: feed.last_fetched_at,
          next_fetch_at: feed.next_fetch_at,
          unread: Map.get(unread_by_feed, feed.id, 0),
          translate_to: feed.translate_to
        }
        |> reject_nils()
      end)

    {:ok, %{feeds: rows, count: length(rows)}}
  end

  defp translation_status(_args) do
    feeds =
      Feeds.list_all_feeds()
      |> Enum.filter(&(is_binary(&1.translate_to) and &1.translate_to != ""))

    if feeds == [] do
      {:ok, %{enabled: false, feeds: []}}
    else
      stats = Enrichment.stats_many(feeds)

      rows =
        Enum.map(feeds, fn feed ->
          s = Map.get(stats, feed.id, %{})

          %{
            feed_id: feed.id,
            title: feed.title,
            translate_to: feed.translate_to,
            total: Map.get(s, :total, 0),
            pending: Map.get(s, :pending, 0),
            paused: Map.get(s, :paused, 0),
            errors: Map.get(s, :errors, 0)
          }
        end)

      {:ok, %{enabled: true, feeds: rows}}
    end
  end

  defp tts_list(args) do
    stats = TTS.stats()

    state =
      case args["state"] do
        s when s in ["requested", "processing", "ready", "failed"] ->
          String.to_existing_atom(s)

        _ ->
          nil
      end

    requests =
      case state do
        nil ->
          []

        atom ->
          TTS.list_requests(state: atom, limit: clamp_limit(args["limit"]))
          |> Enum.map(fn r ->
            %{
              id: r.id,
              entry_id: r.entry_id,
              state: r.state,
              error: r.error,
              retry_at: r.retry_at,
              audio_bytes: r.audio_bytes
            }
            |> reject_nils()
          end)
      end

    {:ok,
     %{
       stats: stats,
       requests: requests,
       filtered_by: state
     }}
  end

  ## Helpers

  defp tts_enabled? do
    cfg = Application.get_env(:earss, :tts, [])
    worker = Keyword.get(cfg, :worker, [])
    Keyword.get(worker, :enabled, false) and is_binary(Keyword.get(cfg, :audio_dir))
  end

  defp clamp_limit(nil), do: 50

  defp clamp_limit(n) when is_integer(n), do: n |> max(1) |> min(200)

  defp clamp_limit(_), do: 50

  defp reject_nils(map), do: Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()
end
