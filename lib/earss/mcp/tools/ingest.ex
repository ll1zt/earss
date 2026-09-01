defmodule Earss.MCP.Tools.Ingest do
  @moduledoc """
  Content ingest: storing what an agent collected, and feeding it into the
  existing translation and TTS pipelines.

  Entries cannot exist without a parent feed, so every ingest targets a
  **container** (`Earss.MCP.Containers`) — a `feed_type: "manual"` feed that
  is never fetched but behaves like any other feed for subscriptions,
  read state, export, translation and TTS.

  ## Reuse, not reimplementation

  The pipelines are not re-driven here. Translation works by marking entries
  pending and letting `Earss.Enrichment.PendingWorker` pick them up, exactly
  as `Earss.Feeds.Fetcher` does after a crawl; TTS works by calling
  `Earss.TTS.record_request/1`, which is idempotent, and letting
  `Earss.TTS.Worker` do the synthesis. Both keep their retry, backoff and
  failure accounting, and neither blocks the tool call — an agent should not
  wait on a provider round trip to learn that its content was stored.
  """

  alias Earss.Enrichment
  alias Earss.Feeds
  alias Earss.MCP.Containers
  alias Earss.MCP.Tool
  alias Earss.Reader
  alias Earss.TTS

  @max_items 100
  @max_chars 500_000

  @doc """
  Every tool this module contributes.
  """
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new(
        name: "ingest_items",
        description:
          "Store content you collected (articles, pages, notes) into a named " <>
            "container so it can be read, translated and listened to like any " <>
            "feed. Containers are created on first use and are never fetched. " <>
            "Items are de-duplicated by link or guid, so re-ingesting the same " <>
            "URL updates it instead of creating a copy. Set pipeline.translate_to " <>
            "to queue translation, or pipeline.tts to queue audio.",
        input_schema: ingest_schema(),
        mutating: true,
        handler: &ingest_items/1
      ),
      Tool.new(
        name: "container_list",
        description: "List the containers you have ingested into, with their entry counts.",
        input_schema: %{
          type: "object",
          properties: %{
            limit: %{type: "integer", description: "Max containers (default 50, max 200)"}
          },
          additionalProperties: false
        },
        mutating: false,
        handler: &container_list/1
      )
    ]
  end

  ## Handlers

  defp ingest_items(args) do
    items = Map.get(args, "items") || []

    cond do
      not is_list(items) ->
        {:error, "items must be an array"}

      items == [] ->
        {:error, "items is empty"}

      length(items) > @max_items ->
        {:error, "too many items: #{length(items)} (max #{@max_items})"}

      true ->
        do_ingest(args, items)
    end
  end

  defp do_ingest(args, items) do
    pipeline = Map.get(args, "pipeline") || %{}

    with {:ok, name} <- container_name(args),
         {:ok, feed} <- ensure_container(name, args, pipeline),
         {:ok, feed} <- maybe_set_translation(feed, pipeline),
         {:ok, upserted} <- upsert_all(feed, items) do
      report(feed, upserted, pipeline)
    end
  end

  defp container_list(args) do
    feeds = Containers.list(limit: Map.get(args, "limit") || 50)

    containers =
      Enum.map(feeds, fn feed ->
        %{
          name: String.trim_leading(feed.link, "earss://agent/"),
          title: feed.title,
          feed_id: feed.id,
          translate_to: feed.translate_to,
          inserted_at: feed.inserted_at
        }
      end)

    {:ok, %{containers: containers, count: length(containers)}}
  end

  defp container_name(args) do
    case Map.get(args, "container") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, "container is required and must be a non-empty string"}
    end
  end

  defp ensure_container(name, args, pipeline) do
    opts = [title: Map.get(args, "title")] ++ translate_opt(pipeline)

    case Containers.ensure(name, opts) do
      {:ok, feed} ->
        # Subscribing is what makes the container show up in the operator's
        # reader and in entry_list; without it the entries exist but are
        # invisible, since the timeline joins through subscriptions. The
        # result is used, so a subscribe failure surfaces instead of leaving
        # entries stored where nothing can read them.
        ensure_subscribed(feed)

      {:error, :invalid_container} ->
        {:error, "invalid container name: use letters, digits, dashes, dots or slashes"}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, Tool.format_changeset(cs)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp translate_opt(%{"translate_to" => lang}) when is_binary(lang) and lang != "",
    do: [translate_to: lang]

  defp translate_opt(_), do: []

  defp ensure_subscribed(feed) do
    case Reader.get_subscription(feed.id) do
      nil -> Reader.subscribe(%{feed_id: feed.id, refresh: false})
      sub -> {:ok, sub}
    end
    |> case do
      {:ok, _sub} -> {:ok, feed}
      {:error, reason} -> {:error, reason}
    end
  end

  # An operator may have set translate_to on this container already; only
  # fill it in when it is empty, so a later ingest cannot quietly change a
  # decision the operator made.
  defp maybe_set_translation(feed, %{"translate_to" => lang})
       when is_binary(lang) and lang != "" do
    if is_nil(feed.translate_to) do
      case Feeds.update_feed(feed, %{"translate_to" => lang}) do
        {:ok, updated} -> {:ok, updated}
        {:error, cs} -> {:error, Tool.format_changeset(cs)}
      end
    else
      {:ok, feed}
    end
  end

  defp maybe_set_translation(feed, _pipeline), do: {:ok, feed}

  defp upsert_all(feed, items) do
    with :ok <- validate_sizes(items),
         {:ok, result} <- Feeds.upsert_entries(feed, Enum.map(items, &normalize_item/1)) do
      {:ok, result}
    end
  end

  defp validate_sizes(items) do
    oversized =
      Enum.reject(items, fn item ->
        size =
          [Map.get(item, "content"), Map.get(item, "summary")]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&String.length/1)
          |> Enum.sum()

        size <= @max_chars
      end)

    if oversized == [] do
      :ok
    else
      {:error, "item content exceeds the #{@max_chars} character limit"}
    end
  end

  # Upsert entries normalizes internally (guid falls back to link, HTML is
  # sanitized, content_hash computed), so this only needs to drop keys we do
  # not want and keep the ones the schema expects.
  defp normalize_item(item) when is_map(item) do
    item
    |> Map.take(~w(title link guid author summary content published_at))
  end

  defp normalize_item(other), do: other

  defp report(feed, %{entries: entries, skipped: skipped}, pipeline) do
    translation = queue_translation(feed, entries)
    tts = queue_tts(entries, pipeline)

    {:ok,
     %{
       container: container_label(feed),
       feed_id: feed.id,
       created: length(entries),
       skipped: skipped,
       entry_ids: Enum.map(entries, & &1.id),
       translation: translation,
       tts: tts
     }}
  end

  # Marking pending is all that is needed: PendingWorker owns the retries.
  defp queue_translation(feed, entries) do
    if entries != [] and is_binary(feed.translate_to) do
      Enrichment.mark_pending(feed, entries)

      %{
        requested: length(entries),
        target: feed.translate_to,
        state: "pending",
        note: "translation runs in the background; check translation_status"
      }
    else
      %{requested: 0, state: "disabled"}
    end
  end

  defp queue_tts(entries, %{"tts" => true}) do
    results = Enum.map(entries, &TTS.record_request(&1.id))
    ok = Enum.count(results, &match?({:ok, _}, &1))

    %{
      requested: ok,
      state: if(ok > 0, do: "pending", else: "disabled"),
      note: "audio is synthesized by the TTS worker; check tts_list"
    }
  end

  defp queue_tts(_entries, _pipeline), do: %{requested: 0, state: "disabled"}

  defp container_label(feed) do
    feed.link
    |> String.trim_leading("earss://agent/")
  end

  defp ingest_schema do
    %{
      type: "object",
      properties: %{
        container: %{
          type: "string",
          description:
            "Container name, e.g. \"research/2026Q3\". Created on first use; " <>
              "no spaces or angle brackets."
        },
        title: %{type: "string", description: "Display title, used when creating the container"},
        items: %{
          type: "array",
          description: "Items to store (max #{@max_items})",
          items: %{
            type: "object",
            properties: %{
              title: %{type: "string"},
              link: %{type: "string", description: "Source URL; also the de-duplication key"},
              guid: %{type: "string", description: "Stable id; defaults to link"},
              author: %{type: "string"},
              summary: %{type: "string"},
              content: %{type: "string", description: "Body text or HTML"},
              published_at: %{
                type: "string",
                description: "ISO 8601 timestamp; defaults to now"
              }
            },
            required: ["title", "link"]
          }
        },
        pipeline: %{
          type: "object",
          description: "Post-ingest pipelines to queue",
          properties: %{
            translate_to: %{
              type: "string",
              description: "Language tag to translate into, e.g. \"zh\""
            },
            tts: %{type: "boolean", description: "Queue audio synthesis for each item"}
          }
        }
      },
      required: ["container", "items"],
      additionalProperties: false
    }
  end
end
