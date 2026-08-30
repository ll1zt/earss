defmodule Earss.MCP.Tools.Subscriptions do
  @moduledoc """
  Subscription management tools: the write half of "an agent can do what the
  operator can".

  Everything goes through `Earss.Reader`, so behaviour matches the admin UI
  and the JSON API exactly — including the refresh side effect after a
  subscribe (which runs outside the DB transaction, as the context does) and
  the SSRF gate on inbound URLs, because `Feeds.ensure_feed/2` resolves the
  link through `Earss.Source.Resolver` and the HTTP client's
  `safe_initial_target?/1`.

  These are `mutating` tools: hidden and rejected under `MCP_READ_ONLY`.
  `feed_unsubscribe` is additionally destructive — it drops the subscription
  and the operator's read state for that feed.
  """

  alias Earss.Feeds
  alias Earss.MCP.Tool
  alias Earss.MCP.Views
  alias Earss.Reader

  @doc """
  Every tool this module contributes.
  """
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new(
        name: "feed_subscribe",
        description:
          "Subscribe to a feed URL (http/https or earss:// plugin route). " <>
            "The feed is fetched once immediately unless refresh is false, " <>
            "then kept up to date by the poller.",
        input_schema: subscribe_schema(),
        mutating: true,
        handler: &feed_subscribe/1
      ),
      Tool.new(
        name: "feed_unsubscribe",
        description:
          "Unsubscribe from a feed. Removes the subscription and the " <>
            "operator's read/starred state for its entries. The feed itself " <>
            "is kept (shared content), and is deleted later by retention if " <>
            "no other subscription remains. This is destructive.",
        input_schema: feed_id_schema("Unsubscribe from this feed"),
        mutating: true,
        handler: &feed_unsubscribe/1
      ),
      Tool.new(
        name: "feed_update",
        description:
          "Update a subscription's settings: display title, refresh " <>
            "interval, category, hidden. Only the fields you pass are " <>
            "changed.",
        input_schema: update_schema(),
        mutating: true,
        handler: &feed_update/1
      ),
      Tool.new(
        name: "feed_refresh",
        description:
          "Fetch a feed right now (force). Returns how many entries were " <>
            "new versus skipped as unchanged.",
        input_schema: feed_id_schema("Refresh this feed"),
        mutating: true,
        handler: &feed_refresh/1
      )
    ]
  end

  ## Handlers

  defp feed_subscribe(args) do
    attrs =
      %{}
      |> put_str("link", args["link"])
      |> put_int("feed_id", args["feed_id"])
      |> put_str("title", args["title"])
      |> put_str("feed_type", args["feed_type"])
      |> put_str("adapter_id", args["adapter_id"])
      |> put_str("source_kind", args["source_kind"])
      |> put_str("custom_title", args["custom_title"])
      |> put_str("category_id", args["category_id"])
      |> put_int("custom_refresh_interval", args["custom_refresh_interval"])
      |> put_bool("is_hidden", args["is_hidden"])
      |> Map.put_new("refresh", Map.get(args, "refresh", true))

    case Reader.subscribe(attrs) do
      {:ok, sub} ->
        {:ok, %{subscription: Views.subscription_summary(sub)}}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset(cs)}

      {:error, reason} when is_atom(reason) ->
        {:error, humanize(reason)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp feed_unsubscribe(%{"feed_id" => feed_id}) when is_integer(feed_id) do
    case Reader.unsubscribe(feed_id) do
      {:ok, _sub} -> {:ok, %{feed_id: feed_id, unsubscribed: true}}
      {:error, :not_found} -> {:error, "no subscription for feed #{feed_id}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp feed_unsubscribe(_), do: {:error, "feed_id is required and must be an integer"}

  defp feed_update(%{"feed_id" => feed_id} = args) when is_integer(feed_id) do
    case Reader.get_subscription(feed_id) do
      nil ->
        {:error, "no subscription for feed #{feed_id}"}

      sub ->
        attrs =
          %{}
          |> put_str("custom_title", args["custom_title"])
          |> put_str("category_id", args["category_id"])
          |> put_int("custom_refresh_interval", args["custom_refresh_interval"])
          |> put_bool("is_hidden", args["is_hidden"])

        if map_size(attrs) == 0 do
          {:error,
           "nothing to update: pass custom_title, category_id, custom_refresh_interval or is_hidden"}
        else
          case Reader.update_subscription(sub, attrs) do
            {:ok, updated} -> {:ok, %{subscription: Views.subscription_summary(updated)}}
            {:error, %Ecto.Changeset{} = cs} -> {:error, format_changeset(cs)}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp feed_update(_), do: {:error, "feed_id is required and must be an integer"}

  defp feed_refresh(%{"feed_id" => feed_id}) when is_integer(feed_id) do
    case Feeds.refresh(feed_id, force: true) do
      {:ok, %{upserted: upserted, skipped: skipped}} ->
        {:ok, %{feed_id: feed_id, upserted: upserted, skipped: skipped}}

      {:ok, :not_modified} ->
        {:ok, %{feed_id: feed_id, upserted: 0, skipped: 0, not_modified: true}}

      {:error, :not_found} ->
        {:error, "feed #{feed_id} not found"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp feed_refresh(_), do: {:error, "feed_id is required and must be an integer"}

  ## Argument plumbing

  defp put_str(map, _key, nil), do: map
  defp put_str(map, _key, ""), do: map
  defp put_str(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp put_str(map, _key, _), do: map

  defp put_int(map, _key, nil), do: map
  defp put_int(map, key, value) when is_integer(value), do: Map.put(map, key, value)
  defp put_int(map, _key, _), do: map

  defp put_bool(map, _key, nil), do: map
  defp put_bool(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp put_bool(map, _key, _), do: map

  defp humanize(:feed_not_found), do: "feed not found"
  defp humanize(:missing_feed), do: "provide either link or feed_id"
  defp humanize(:invalid_link), do: "the link could not be resolved to a feed"
  defp humanize(other), do: inspect(other)

  defp format_changeset(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  defp feed_id_schema(description) do
    %{
      type: "object",
      properties: %{feed_id: %{type: "integer", description: description}},
      required: ["feed_id"],
      additionalProperties: false
    }
  end

  defp subscribe_schema do
    %{
      type: "object",
      properties: %{
        link: %{
          type: "string",
          description: "Feed URL (http/https) or earss:// plugin route"
        },
        feed_id: %{type: "integer", description: "Subscribe to an existing feed by id"},
        title: %{type: "string", description: "Feed title (used when creating a new feed)"},
        custom_title: %{type: "string", description: "Personal display title"},
        category_id: %{type: "integer", description: "Folder to place the subscription in"},
        custom_refresh_interval: %{
          type: "integer",
          description: "Minutes between fetches (15–10080)"
        },
        is_hidden: %{type: "boolean", description: "Hide from the timeline"},
        refresh: %{type: "boolean", description: "Fetch once immediately (default true)"}
      },
      anyOf: [
        %{required: ["link"]},
        %{required: ["feed_id"]}
      ],
      additionalProperties: false
    }
  end

  defp update_schema do
    %{
      type: "object",
      properties: %{
        feed_id: %{type: "integer", description: "The subscription's feed id"},
        custom_title: %{type: "string", description: "New display title"},
        category_id: %{type: "integer", description: "Move to this category"},
        custom_refresh_interval: %{type: "integer", description: "Minutes between fetches"},
        is_hidden: %{type: "boolean", description: "Hide or unhide"}
      },
      required: ["feed_id"],
      additionalProperties: false
    }
  end
end
