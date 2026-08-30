defmodule Earss.MCP.Tools.Backfill do
  @moduledoc """
  Backfill: fetch content older than a feed's window and ingest it.

  Feeds only expose their most recent items. Getting history is a
  site-specific problem — an archive page, a paginated API, a cursor the
  adapter already keeps — so the *how* belongs to the source plugin, not to
  this host. This tool only orchestrates:

    1. resolve the feed's adapter
    2. if the adapter implements the optional `backfill/2` callback, call it
    3. run the returned entries through the same ingest path as a normal
       crawl (`Feeds.ingest_payload/3`), so ordering, sanitisation and
       content-hash de-duplication are identical
    4. rely on that same ingest path for the translation hook

  An adapter without `backfill/2` gets a clear answer rather than a silent
  no-op: the tool reports that the source does not support history fetching.
  """

  alias Earss.Feeds
  alias Earss.Feeds.Feed
  alias Earss.MCP.Tool
  alias Earss.Source.Resolver

  @default_limit 50

  @doc """
  Every tool this module contributes.
  """
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new(
        name: "feed_backfill",
        description:
          "Fetch older articles from a feed that are outside its normal " <>
            "window and store them, exactly as a scheduled refresh would. " <>
            "Only works for sources whose plugin supports history (some " <>
            "feeds have no way to enumerate their archive at all).",
        input_schema: %{
          type: "object",
          properties: %{
            feed_id: %{type: "integer", description: "The feed to backfill"},
            limit: %{
              type: "integer",
              description: "Max items to fetch (default #{@default_limit})"
            }
          },
          required: ["feed_id"],
          additionalProperties: false
        },
        mutating: true,
        handler: &feed_backfill/1
      )
    ]
  end

  defp feed_backfill(%{"feed_id" => feed_id} = args) when is_integer(feed_id) do
    with {:ok, feed} <- fetch_feed(feed_id),
         {:ok, adapter} <- fetch_adapter(feed),
         :ok <- ensure_supported(adapter) do
      do_backfill(feed, adapter, limit_arg(Map.get(args, "limit")))
    end
  end

  defp feed_backfill(_), do: {:error, "feed_id is required and must be an integer"}

  defp fetch_feed(id) do
    case Feeds.get_feed(id) do
      %Feed{} = feed -> {:ok, feed}
      nil -> {:error, "feed #{id} not found"}
    end
  end

  # Resolver.adapter_module/1 falls back to native for unknown ids, so a
  # backfill of a feed whose adapter vanished would silently run the native
  # fetch path — which has no backfill. That is fine: ensure_supported/1 then
  # reports it cleanly instead of guessing.
  defp fetch_adapter(feed), do: {:ok, Resolver.adapter_module(feed)}

  defp ensure_supported(adapter) do
    if function_exported?(adapter, :backfill, 2) do
      :ok
    else
      {:error,
       "this source's adapter does not support backfill — history fetching " <>
         "is a per-site feature, so there is nothing to call"}
    end
  end

  defp do_backfill(feed, adapter, limit) do
    case adapter.backfill(feed, limit: limit) do
      {:ok, payload} when is_map(payload) ->
        ingest(feed, payload)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ingest(feed, payload) do
    case Feeds.ingest_payload(feed, payload) do
      {:ok, %{upserted: upserted, skipped: skipped}} ->
        {:ok,
         %{
           feed_id: feed.id,
           fetched: upserted + skipped,
           upserted: upserted,
           skipped: skipped,
           # The ingest path runs the same translation hook as a crawl; if
           # the feed translates, newly stored entries are marked pending
           # there and translated by the PendingWorker.
           translation: translation_state(feed)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp translation_state(%Feed{translate_to: lang}) when is_binary(lang),
    do: %{state: "pending", target: lang}

  defp translation_state(_), do: %{state: "disabled"}

  defp limit_arg(nil), do: @default_limit

  defp limit_arg(n) when is_integer(n), do: n |> max(1) |> min(200)

  defp limit_arg(_), do: @default_limit
end
