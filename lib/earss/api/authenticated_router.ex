defmodule Earss.API.AuthenticatedRouter do
  @moduledoc false

  use Plug.Router

  import Ecto.Query, warn: false

  alias Earss.API.{Auth, JSON, Views}
  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.Export
  alias Earss.Reader.Category
  alias Earss.Reader.Subscription
  alias Earss.Repo

  plug(:match)
  plug(Auth)
  plug(:dispatch)

  get "/me" do
    user = conn.assigns.current_user
    JSON.json(conn, 200, %{user: Views.user(user)})
  end

  ## Categories

  get "/categories" do
    cats = Reader.list_categories(conn.assigns.current_user)
    JSON.json(conn, 200, %{categories: Enum.map(cats, &Views.category/1)})
  end

  post "/categories" do
    case Reader.create_category(conn.assigns.current_user, body(conn)) do
      {:ok, cat} -> JSON.json(conn, 201, %{category: Views.category(cat)})
      {:error, %Ecto.Changeset{} = cs} -> JSON.changeset_error(conn, cs)
    end
  end

  patch "/categories/:id" do
    with {:ok, cat} <- owned_category(conn, id),
         {:ok, cat} <- Reader.update_category(cat, body(conn)) do
      JSON.json(conn, 200, %{category: Views.category(cat)})
    else
      {:error, :not_found} -> JSON.error(conn, 404, "not_found")
      {:error, %Ecto.Changeset{} = cs} -> JSON.changeset_error(conn, cs)
    end
  end

  delete "/categories/:id" do
    with {:ok, cat} <- owned_category(conn, id),
         {:ok, _} <- Reader.delete_category(cat) do
      JSON.json(conn, 200, %{ok: true})
    else
      {:error, :not_found} -> JSON.error(conn, 404, "not_found")
      {:error, %Ecto.Changeset{} = cs} -> JSON.changeset_error(conn, cs)
    end
  end

  ## Subscriptions

  get "/subscriptions" do
    include_hidden = query_bool(conn, "include_hidden", true)
    with_unread = query_bool(conn, "with_unread_count", true)

    subs =
      Reader.list_subscriptions(conn.assigns.current_user,
        include_hidden: include_hidden,
        with_unread_count: with_unread
      )

    JSON.json(conn, 200, %{subscriptions: Enum.map(subs, &Views.subscription/1)})
  end

  post "/entries/mark_read" do
    attrs = body(conn)

    opts =
      %{}
      |> then(fn m ->
        if ids = Map.get(attrs, "ids"), do: Map.put(m, :ids, ids), else: m
      end)
      |> then(fn m ->
        if fid = Map.get(attrs, "feed_id"), do: Map.put(m, :feed_id, fid), else: m
      end)

    case Reader.mark_entries_read(conn.assigns.current_user, opts) do
      {:ok, result} -> JSON.json(conn, 200, result)
      {:error, :not_found} -> JSON.error(conn, 404, "not_found")
    end
  end

  get "/opml/export" do
    case Reader.export_opml(conn.assigns.current_user) do
      {:ok, xml} ->
        conn
        |> put_resp_content_type("text/x-opml+xml")
        |> send_resp(200, xml)
    end
  end

  post "/opml/import" do
    xml =
      case body(conn) do
        %{"opml" => opml} when is_binary(opml) -> opml
        %{"xml" => xml} when is_binary(xml) -> xml
        _ -> nil
      end

    refresh? =
      case Map.get(body(conn), "refresh") do
        true -> true
        "true" -> true
        _ -> false
      end

    if is_nil(xml) or String.trim(xml) == "" do
      JSON.error(conn, 400, "missing_opml")
    else
      case Reader.import_opml(conn.assigns.current_user, xml, refresh: refresh?) do
        {:ok, stats} -> JSON.json(conn, 200, stats)
        {:error, reason} -> JSON.error(conn, 422, "opml_parse_failed", %{reason: inspect(reason)})
      end
    end
  end

  post "/subscriptions" do
    attrs = body(conn)

    attrs =
      case Map.get(attrs, "refresh") do
        false -> Map.put(attrs, "refresh", false)
        "false" -> Map.put(attrs, "refresh", false)
        true -> Map.put(attrs, "refresh", true)
        "true" -> Map.put(attrs, "refresh", true)
        nil -> Map.put(attrs, "refresh", true)
        _ -> Map.put(attrs, "refresh", true)
      end

    case Reader.subscribe(conn.assigns.current_user, attrs) do
      {:ok, sub} ->
        JSON.json(conn, 201, %{subscription: Views.subscription(sub)})

      {:error, %Ecto.Changeset{} = cs} ->
        JSON.changeset_error(conn, cs)

      {:error, :feed_not_found} ->
        JSON.error(conn, 404, "feed_not_found")

      {:error, :missing_feed} ->
        JSON.error(conn, 400, "missing_feed")

      {:error, reason} ->
        JSON.error(conn, 400, inspect(reason))
    end
  end

  patch "/subscriptions/:id" do
    with {:ok, sub} <- owned_subscription(conn, id),
         {:ok, sub} <- Reader.update_subscription(sub, body(conn)) do
      JSON.json(conn, 200, %{subscription: Views.subscription(sub)})
    else
      {:error, :not_found} -> JSON.error(conn, 404, "not_found")
      {:error, %Ecto.Changeset{} = cs} -> JSON.changeset_error(conn, cs)
    end
  end

  delete "/subscriptions/:id" do
    with {:ok, sub} <- owned_subscription(conn, id),
         {:ok, _} <- Reader.unsubscribe(conn.assigns.current_user, sub.feed_id) do
      JSON.json(conn, 200, %{ok: true})
    else
      {:error, :not_found} -> JSON.error(conn, 404, "not_found")
    end
  end

  ## Entries timeline

  get "/entries" do
    opts = entry_list_opts(conn)
    rows = Reader.list_entries(conn.assigns.current_user, opts)
    translate_to = empty_to_nil(conn.query_params["translate_to"])

    entries =
      if translate_to do
        translations = translation_map(rows, translate_to)
        Enum.map(rows, &Views.entry_row(&1, Map.get(translations, &1.entry.id)))
      else
        Enum.map(rows, &Views.entry_row/1)
      end

    JSON.json(conn, 200, %{entries: entries})
  end

  post "/entries/:id/read" do
    state_action(conn, id, &Reader.mark_read/2)
  end

  post "/entries/:id/unread" do
    state_action(conn, id, &Reader.mark_unread/2)
  end

  post "/entries/:id/star" do
    case Reader.set_star(conn.assigns.current_user, id_int(id), true) do
      {:ok, state} -> JSON.json(conn, 200, %{state: state_view(state)})
      {:error, :not_found} -> JSON.error(conn, 404, "not_found")
    end
  end

  delete "/entries/:id/star" do
    case Reader.set_star(conn.assigns.current_user, id_int(id), false) do
      {:ok, state} -> JSON.json(conn, 200, %{state: state_view(state)})
      {:error, :not_found} -> JSON.error(conn, 404, "not_found")
    end
  end

  ## Export

  get "/export/starred" do
    user = conn.assigns.current_user

    Export.send_download(conn, export_format(conn), Export.starred(user),
      base: "earss-starred-#{user.username}",
      scope: "starred",
      user: user.username
    )
  end

  get "/export/feed/:feed_id" do
    user = conn.assigns.current_user

    case Export.feed(user, feed_id) do
      {:ok, feed, stream} ->
        Export.send_download(conn, export_format(conn), stream,
          base: "earss-feed-#{feed.id}-#{feed.title}",
          scope: "feed",
          user: user.username,
          feed: %{title: feed.title, link: feed.link}
        )

      {:error, :not_found} ->
        JSON.error(conn, 404, "not_found")
    end
  end

  get "/export/all" do
    user = conn.assigns.current_user

    if user.user_type == "admin" do
      Export.send_download(conn, export_format(conn), Export.all(),
        base: "earss-all",
        scope: "all"
      )
    else
      JSON.error(conn, 403, "forbidden")
    end
  end

  ## Force refresh

  post "/feeds/:id/refresh" do
    feed_id = id_int(id)
    user = conn.assigns.current_user

    case Reader.get_subscription(user, feed_id) do
      nil ->
        JSON.error(conn, 404, "not_found")

      _sub ->
        case Feeds.refresh(feed_id) do
          {:ok, :not_modified} ->
            JSON.json(conn, 200, %{result: "not_modified"})

          {:ok, %{upserted: n, skipped: s, feed: feed}} ->
            JSON.json(conn, 200, %{
              result: "ok",
              upserted: n,
              skipped: s,
              feed: Views.feed(feed)
            })

          {:error, :not_found} ->
            JSON.error(conn, 404, "not_found")

          {:error, {:http, reason}} ->
            JSON.error(conn, 502, "http_error", %{reason: inspect(reason)})

          {:error, {:parse, reason}} ->
            JSON.error(conn, 422, "parse_error", %{reason: inspect(reason)})

          {:error, %Ecto.Changeset{} = cs} ->
            JSON.changeset_error(conn, cs)

          {:error, reason} ->
            JSON.error(conn, 500, "refresh_failed", %{reason: inspect(reason)})
        end
    end
  end

  match _ do
    JSON.error(conn, 404, "not_found")
  end

  ## Helpers

  defp state_action(conn, id, fun) do
    case fun.(conn.assigns.current_user, id_int(id)) do
      {:ok, state} -> JSON.json(conn, 200, %{state: state_view(state)})
      {:error, :not_found} -> JSON.error(conn, 404, "not_found")
    end
  end

  defp state_view(state) do
    %{
      entry_id: state.entry_id,
      is_read: state.is_read,
      is_star: state.is_star,
      read_at: state.read_at
    }
  end

  defp body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> %{}
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp owned_category(conn, id) do
    user = conn.assigns.current_user

    case Reader.get_category(id_int(id)) do
      %Category{user_id: uid} = cat when uid == user.id -> {:ok, cat}
      _ -> {:error, :not_found}
    end
  end

  defp owned_subscription(conn, id) do
    user = conn.assigns.current_user

    case Repo.get(Subscription, id_int(id)) do
      %Subscription{user_id: uid} = sub when uid == user.id ->
        {:ok, Repo.preload(sub, [:feed, :category])}

      _ ->
        {:error, :not_found}
    end
  end

  defp export_format(conn) do
    case conn.query_params["format"] do
      "markdown" -> :markdown
      "md" -> :markdown
      _ -> :json
    end
  end

  defp entry_list_opts(conn) do
    q = conn.query_params

    []
    |> maybe_kw(:limit, int_or_nil(q["limit"]))
    |> maybe_kw(:offset, int_or_nil(q["offset"]))
    |> maybe_kw(:feed_id, int_or_nil(q["feed_id"]))
    |> maybe_put_category(q["category_id"])
    |> Keyword.put(:unread_only, query_bool(conn, "unread", false))
    |> Keyword.put(:starred_only, query_bool(conn, "starred", false))
    |> Keyword.put(:include_hidden, query_bool(conn, "include_hidden", false))
  end

  defp maybe_put_category(opts, nil), do: opts
  defp maybe_put_category(opts, ""), do: opts
  defp maybe_put_category(opts, "none"), do: Keyword.put(opts, :category_id, :none)
  defp maybe_put_category(opts, val), do: maybe_kw(opts, :category_id, int_or_nil(val))

  defp maybe_kw(opts, _k, nil), do: opts
  defp maybe_kw(opts, k, v), do: Keyword.put(opts, k, v)

  defp query_bool(conn, key, default) do
    case conn.query_params[key] do
      nil -> default
      "true" -> true
      "1" -> true
      "false" -> false
      "0" -> false
      true -> true
      false -> false
      _ -> default
    end
  end

  defp int_or_nil(nil), do: nil
  defp int_or_nil(i) when is_integer(i), do: i

  defp int_or_nil(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v

  defp translation_map(rows, lang) do
    ids = Enum.map(rows, & &1.entry.id)

    from(t in Earss.Feeds.EntryTranslation,
      where: t.lang == ^lang and t.entry_id in ^ids
    )
    |> Repo.all()
    |> Map.new(fn t -> {t.entry_id, t} end)
  end

  defp id_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, _} -> i
      :error -> -1
    end
  end

  defp id_int(id) when is_integer(id), do: id
end
