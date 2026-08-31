defmodule Earss.MCP.Tools.Pipelines do
  @moduledoc """
  Manual control of the translation and TTS pipelines.

  Ingest and crawl trigger these automatically, but an agent often needs to
  act on them directly: translate a feed now, retry a failed synthesis,
  queue a specific article for audio, or publish an original when a
  translator is stuck. These tools are the control plane for that.

  Both feed-level and entry-level variants exist because the two questions
  are different: "translate everything this feed is waiting on" and "turn
  this one article into audio". The destructive ones (publishing an original
  instead of translating, deleting a TTS request) run through the two-phase
  confirm flow.
  """

  alias Earss.Enrichment
  alias Earss.Feeds
  alias Earss.Feeds.Feed
  alias Earss.MCP.Tool
  alias Earss.TTS

  @doc """
  Every tool this module contributes.
  """
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new(
        name: "translate_feed",
        description:
          "Immediately translate every entry of a feed that is waiting for " <>
            "translation, including ones that had been paused after repeated " <>
            "failures. Returns how many translations were stored.",
        input_schema: feed_id_schema("Translate every pending entry of this feed"),
        mutating: true,
        handler: &translate_feed/1
      ),
      Tool.new(
        name: "translate_entry",
        description:
          "Immediately translate one article into its feed's target language. " <>
            "Useful when a specific article matters now rather than whenever " <>
            "the background worker gets to it.",
        input_schema: entry_id_schema("Translate this entry"),
        mutating: true,
        handler: &translate_entry/1
      ),
      Tool.new(
        name: "translation_publish_original",
        description:
          "Give up on translating a feed's pending entries and publish their " <>
            "original text instead, so they become visible to readers. The " <>
            "opposite of waiting for the translator. Destructive: any stored " <>
            "translations for those entries are no longer what readers see.",
        input_schema: feed_id_schema("Publish originals for this feed"),
        mutating: true,
        destructive: true,
        impact: &publish_impact/1,
        handler: &translation_publish_original/1
      ),
      Tool.new(
        name: "tts_request",
        description:
          "Queue an article for audio synthesis (listen-later). Idempotent: " <>
            "if it is already queued or ready, nothing changes.",
        input_schema: entry_id_schema("Synthesize this entry"),
        mutating: true,
        handler: &tts_request/1
      ),
      Tool.new(
        name: "tts_requeue",
        description:
          "Retry a TTS request that failed or was requested but never " <>
            "synthesized.",
        input_schema: %{
          type: "object",
          properties: %{request_id: %{type: "integer", description: "The TTS request id"}},
          required: ["request_id"],
          additionalProperties: false
        },
        mutating: true,
        handler: &tts_requeue/1
      ),
      Tool.new(
        name: "tts_delete",
        description:
          "Delete a TTS request and its audio file. Destructive: the " <>
            "synthesized audio is gone and the entry must be re-requested to " <>
            "get it back.",
        input_schema: %{
          type: "object",
          properties: %{
            request_id: %{type: "integer", description: "The TTS request id"},
            confirm: %{
              type: "boolean",
              description: "Set true to actually delete. Without it only a report is returned."
            }
          },
          required: ["request_id"],
          additionalProperties: false
        },
        mutating: true,
        destructive: true,
        impact: &tts_delete_impact/1,
        handler: &tts_delete/1
      )
    ]
  end

  ## Translation handlers

  defp translate_feed(%{"feed_id" => id}) when is_integer(id) do
    case Feeds.get_feed(id) do
      nil ->
        {:error, "feed #{id} not found"}

      %Feed{} = feed ->
        case Enrichment.translate_feed_pending(feed) do
          :no_enricher -> {:error, "no translator plugin is registered"}
          n -> {:ok, %{feed_id: id, translated: n}}
        end
    end
  end

  defp translate_feed(_), do: {:error, "feed_id is required and must be an integer"}

  defp translate_entry(%{"id" => id}) when is_integer(id) do
    with {:ok, entry} <- fetch_entry(id),
         {:ok, feed} <- fetch_feed(entry.feed_id) do
      case Enrichment.enrich_entry(entry, feed) do
        :no_enricher -> {:error, "no translator plugin is registered"}
        {:ok, n} -> {:ok, %{id: id, translated: n}}
      end
    end
  end

  defp translate_entry(_), do: {:error, "id is required and must be an integer"}

  defp translation_publish_original(%{"feed_id" => id}) when is_integer(id) do
    case Feeds.get_feed(id) do
      nil ->
        {:error, "feed #{id} not found"}

      %Feed{} = feed ->
        _ = Enrichment.publish_pending(feed)
        {:ok, %{feed_id: id, published: true}}
    end
  end

  defp translation_publish_original(_), do: {:error, "feed_id is required and must be an integer"}

  ## TTS handlers

  defp tts_request(%{"id" => id}) when is_integer(id) do
    case TTS.record_request(id) do
      {:ok, req} -> {:ok, %{id: id, request_id: req.id, state: req.state}}
      {:error, :unknown_entry} -> {:error, "entry #{id} not found"}
    end
  end

  defp tts_request(_), do: {:error, "id is required and must be an integer"}

  defp tts_requeue(%{"request_id" => id}) when is_integer(id) do
    case TTS.requeue(id) do
      {:ok, req} -> {:ok, %{request_id: id, state: req.state}}
      {:error, :not_found} -> {:error, "no TTS request #{id}"}
      {:error, :invalid_state} -> {:error, "TTS request #{id} is not in a retryable state"}
    end
  end

  defp tts_requeue(_), do: {:error, "request_id is required and must be an integer"}

  defp tts_delete(%{"request_id" => id}) when is_integer(id) do
    case TTS.delete_request(id) do
      {:ok, %{row: row, file: file}} ->
        {:ok, %{request_id: id, deleted: true, row: row, file: file}}

      {:error, :not_found} ->
        {:error, "no TTS request #{id}"}

      {:error, :invalid_state} ->
        {:error, "TTS request #{id} is being processed; try later"}
    end
  end

  defp tts_delete(_), do: {:error, "request_id is required and must be an integer"}

  ## Confirmation-phase reports

  defp publish_impact(%{"feed_id" => id}) when is_integer(id) do
    case Feeds.get_feed(id) do
      nil ->
        %{affected: :none, reason: "feed #{id} not found"}

      feed ->
        pending = count_pending(feed.id)

        %{
          affected: :translations,
          feed_id: id,
          feed_title: feed.title || feed.link,
          pending_entries_published_as_original: pending
        }
    end
  end

  defp publish_impact(_), do: %{}

  defp tts_delete_impact(%{"request_id" => id}) when is_integer(id) do
    case TTS.list_requests() |> Enum.find(&(&1.id == id)) do
      nil ->
        %{affected: :none, reason: "no TTS request #{id}"}

      req ->
        %{
          affected: :tts_request,
          request_id: id,
          entry_id: req.entry_id,
          state: req.state,
          audio: if(is_binary(req.audio_path), do: req.audio_path, else: nil)
        }
    end
  end

  defp tts_delete_impact(_), do: %{}

  ## Helpers

  defp fetch_entry(id) do
    case Feeds.get_entry(id) do
      nil -> {:error, "entry #{id} not found"}
      entry -> {:ok, entry}
    end
  end

  defp fetch_feed(feed_id) do
    case Feeds.get_feed(feed_id) do
      nil -> {:error, "feed #{feed_id} not found"}
      feed -> {:ok, feed}
    end
  end

  defp count_pending(feed_id) do
    import Ecto.Query

    Earss.Feeds.Entry
    |> where([e], e.feed_id == ^feed_id and not is_nil(e.translation_pending_at))
    |> select([e], count(e.id))
    |> Earss.Repo.one()
    |> Kernel.||(0)
  end

  defp feed_id_schema(description) do
    %{
      type: "object",
      properties: %{
        feed_id: %{type: "integer", description: description},
        confirm: %{
          type: "boolean",
          description: "Set true to actually execute. Without it only a report is returned."
        }
      },
      required: ["feed_id"],
      additionalProperties: false
    }
  end

  defp entry_id_schema(description) do
    %{
      type: "object",
      properties: %{id: %{type: "integer", description: description}},
      required: ["id"],
      additionalProperties: false
    }
  end
end
