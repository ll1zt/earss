defmodule Earss.Fever do
  @moduledoc """
  Fever API response assembly. See `docs/fever.md`.
  """

  alias Earss.API.Translation
  alias Earss.OperatorAuth
  alias Earss.Reader

  @api_version 3

  @doc """
  Handle a Fever request after parameters are normalized to a string-key map.
  """
  @spec handle(map()) :: map()
  def handle(params) when is_map(params) do
    params = stringify_keys(params)
    api_key = params["api_key"]

    if OperatorAuth.verify_fever_api_key(api_key || "") do
      base(true)
      |> maybe_put_groups(params)
      |> maybe_put_feeds(params)
      |> maybe_put_favicons(params)
      |> maybe_put_items(params)
      |> maybe_put_unread_ids(params)
      |> maybe_put_saved_ids(params)
      |> maybe_mark(params)
    else
      base(false)
    end
  end

  defp base(auth?) do
    %{
      "api_version" => @api_version,
      "auth" => if(auth?, do: 1, else: 0),
      "last_refreshed_on_time" => now_unix()
    }
  end

  defp maybe_put_groups(resp, params) do
    if flag?(params, "groups") do
      groups =
        Reader.list_categories()
        |> Enum.map(fn c ->
          %{"id" => c.id, "title" => c.name}
        end)

      Map.put(resp, "groups", groups)
    else
      resp
    end
  end

  defp maybe_put_feeds(resp, params) do
    if flag?(params, "feeds") or flag?(params, "groups") do
      subs = Reader.list_subscriptions(include_hidden: false)

      feeds =
        Enum.map(subs, fn sub ->
          feed = sub.feed
          title = sub.custom_title || feed.title || feed.link

          %{
            "id" => feed.id,
            "favicon_id" => 0,
            "title" => title,
            "url" => feed.link,
            "site_url" => feed.site_url || "",
            "is_spark" => 0,
            "last_updated_on_time" => unix(feed.last_fetched_at) || 0
          }
        end)

      # Fever spec: either `groups` or `feeds` includes feeds_groups.
      feeds_groups =
        subs
        |> Enum.group_by(fn sub -> sub.category_id || 0 end)
        |> Enum.map(fn {group_id, group_subs} ->
          feed_ids =
            group_subs
            |> Enum.map(& &1.feed_id)
            |> Enum.join(",")

          %{"group_id" => group_id, "feed_ids" => feed_ids}
        end)

      resp
      |> Map.put("feeds", feeds)
      |> Map.put("feeds_groups", feeds_groups)
    else
      resp
    end
  end

  defp maybe_put_favicons(resp, params) do
    if flag?(params, "favicons") do
      Map.put(resp, "favicons", [])
    else
      resp
    end
  end

  defp maybe_put_items(resp, params) do
    if flag?(params, "items") do
      since_id = int_param(params["since_id"])
      max_id = int_param(params["max_id"])

      with_ids =
        case params["with_ids"] do
          nil -> []
          "" -> []
          s when is_binary(s) -> String.split(s, ",", trim: true)
          list when is_list(list) -> list
          _ -> []
        end

      rows =
        Reader.list_fever_items(
          since_id: since_id,
          max_id: max_id,
          with_ids: with_ids,
          limit: 50
        )

      rows = Translation.attach(rows, original: params["original"] == "1")

      items =
        Enum.map(rows, fn row ->
          e = row.entry

          %{
            "id" => e.id,
            "feed_id" => e.feed_id,
            "title" => Translation.title(row),
            "author" => e.author || "",
            "html" => Translation.content(row),
            "url" => e.link || "",
            "is_saved" => if(row.is_star, do: 1, else: 0),
            "is_read" => if(row.is_read, do: 1, else: 0),
            "created_on_time" => unix(e.published_at) || unix(e.inserted_at) || 0
          }
        end)

      # Fever: total_items is the full store count, not the page size.
      total = Reader.count_fever_items()

      resp
      |> Map.put("items", items)
      |> Map.put("total_items", total)
    else
      resp
    end
  end

  defp maybe_put_unread_ids(resp, params) do
    if flag?(params, "unread_item_ids") do
      ids = Reader.list_unread_entry_ids() |> Enum.join(",")
      Map.put(resp, "unread_item_ids", ids)
    else
      resp
    end
  end

  defp maybe_put_saved_ids(resp, params) do
    if flag?(params, "saved_item_ids") do
      ids = Reader.list_starred_entry_ids() |> Enum.join(",")
      Map.put(resp, "saved_item_ids", ids)
    else
      resp
    end
  end

  defp maybe_mark(resp, params) do
    case params["mark"] do
      nil ->
        resp

      "" ->
        resp

      "item" ->
        mark_item(params)
        resp

      "feed" ->
        mark_feed(params)
        resp

      "group" ->
        mark_group(params)
        resp

      _ ->
        resp
    end
  end

  defp mark_item(params) do
    id = int_param(params["id"])

    if id do
      case params["as"] do
        "read" -> Reader.mark_read(id)
        "unread" -> Reader.mark_unread(id)
        "saved" -> Reader.set_star(id, true)
        "unsaved" -> Reader.set_star(id, false)
        _ -> :ok
      end
    end
  end

  defp mark_feed(params) do
    if params["as"] == "read" do
      feed_id = int_param(params["id"])
      before = params["before"]
      if feed_id, do: Reader.mark_entries_read(feed_id: feed_id, before: before)
    end
  end

  defp mark_group(params) do
    if params["as"] == "read" do
      group_id = int_param(params["id"]) || 0
      before = params["before"]

      Reader.mark_entries_read(category_id: group_id, before: before)
    end
  end

  defp flag?(params, name) do
    # Fever clients send bare flags as empty keys: groups&feeds
    Map.has_key?(params, name) or Map.get(params, name) in [true, "true", "1", ""]
  end

  defp int_param(nil), do: nil
  defp int_param(i) when is_integer(i), do: i

  defp int_param(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp int_param(_), do: nil

  defp unix(nil), do: nil
  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp unix(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  defp now_unix, do: System.system_time(:second)

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end
end
