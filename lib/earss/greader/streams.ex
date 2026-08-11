defmodule Earss.GReader.Streams do
  @moduledoc false

  import Ecto.Query, warn: false

  require Earss.Translate.Visibility

  alias Earss.Repo
  alias Earss.Reader
  alias Earss.Reader.User
  alias Earss.Reader.Subscription
  alias Earss.Feeds
  alias Earss.Feeds.Entry
  alias Earss.Feeds.Feed
  alias Earss.Reader.EntryState
  alias Earss.Reader.Category
  alias Earss.GReader.Ids
  alias Earss.GReader.Format
  alias Earss.API.Translation

  def stream_item_ids(%User{} = user, stream_id, opts \\ []) do
    n = opts |> Keyword.get(:n, 1000) |> min(10_000)
    xt_read? = Keyword.get(opts, :exclude_read, false)
    continuation = Keyword.get(opts, :continuation)
    ot = Keyword.get(opts, :ot)
    nt = Keyword.get(opts, :nt)

    {query, _} = stream_entry_query(user, stream_id, exclude_read: xt_read?)
    # Unread sync (xt=read) must not apply ot — NNW often sends ot≈now which
    # would hide every already-ingested unread item.
    query =
      if xt_read? do
        query
      else
        apply_time_bounds(query, ot, nt)
      end

    query =
      from([e, s, st] in query,
        order_by: [desc: e.id],
        limit: ^n
      )

    query =
      case Ids.parse_continuation(continuation) do
        nil -> query
        cid -> from([e, s, st] in query, where: e.id < ^cid)
      end

    query =
      from([e, s, st] in query,
        join: f in Feed,
        on: f.id == e.feed_id,
        where:
          not fragment(
            "coalesce(?, ?) IS NOT NULL AND ? > (now() AT TIME ZONE 'UTC') - (? * interval '1 minute') AND NOT EXISTS (SELECT 1 FROM entry_translations t WHERE t.entry_id = ? AND t.lang = coalesce(?, ?))",
            s.translate_to,
            f.translate_to,
            e.inserted_at,
            ^Earss.Translate.Visibility.window_minutes(),
            e.id,
            s.translate_to,
            f.translate_to
          )
      )

    rows =
      Repo.all(
        from([e, s, st, f] in query,
          select: {e.id, e.published_at, e.inserted_at}
        )
      )

    # NetNewsWire posts contents with decimal i= values.
    # Prefer article published time for itemRefs (matches contents `published`).
    item_refs =
      Enum.map(rows, fn {id, pub, ins} ->
        ts = unix(pub) || unix(ins) || 0

        %{
          "id" => Integer.to_string(id),
          "directStreamIds" => [],
          "timestampUsec" => "#{ts}000000"
        }
      end)

    # Only continue if we filled a full page (otherwise c=min_id caused empty loops).
    cont =
      if length(rows) >= n and rows != [] do
        {last_id, _, _} = List.last(rows)
        Integer.to_string(last_id)
      else
        nil
      end

    base = %{"itemRefs" => item_refs}
    if cont, do: Map.put(base, "continuation", cont), else: base
  end

  ## Stream contents

  def stream_contents(%User{} = user, stream_id, opts \\ []) do
    n = opts |> Keyword.get(:n, 50) |> min(100)
    xt_read? = Keyword.get(opts, :exclude_read, false)
    continuation = Keyword.get(opts, :continuation)
    ot = Keyword.get(opts, :ot)
    nt = Keyword.get(opts, :nt)

    {query, title} = stream_entry_query(user, stream_id, exclude_read: xt_read?)

    query =
      if xt_read? do
        query
      else
        apply_time_bounds(query, ot, nt)
      end

    query =
      from([e, s, st] in query,
        order_by: [desc: e.id],
        limit: ^n
      )

    query =
      case Ids.parse_continuation(continuation) do
        nil -> query
        cid -> from([e, s, st] in query, where: e.id < ^cid)
      end

    rows =
      Repo.all(
        from([e, s, st] in query,
          join: f in Feed,
          on: f.id == e.feed_id,
          left_join: c in Category,
          on: c.id == s.category_id,
          where:
            not fragment(
              "coalesce(?, ?) IS NOT NULL AND ? > (now() AT TIME ZONE 'UTC') - (? * interval '1 minute') AND NOT EXISTS (SELECT 1 FROM entry_translations t WHERE t.entry_id = ? AND t.lang = coalesce(?, ?))",
              s.translate_to,
              f.translate_to,
              e.inserted_at,
              ^Earss.Translate.Visibility.window_minutes(),
              e.id,
              s.translate_to,
              f.translate_to
            ),
          select: %{
            entry: e,
            feed: f,
            is_read: fragment("coalesce(?, false)", st.is_read),
            is_star: fragment("coalesce(?, false)", st.is_star),
            custom_title: s.custom_title,
            category_name: c.name,
            sub_translate_to: s.translate_to,
            original_layout: s.original_layout
          }
        )
      )

    rows = Translation.attach(user, rows, original: Keyword.get(opts, :original, false))
    items = Enum.map(rows, &Format.entry_item/1)

    cont =
      if length(rows) >= n and rows != [] do
        to_string(List.last(rows).entry.id)
      else
        nil
      end

    %{
      "direction" => "ltr",
      "id" => stream_id || "user/-/state/com.google/reading-list",
      "title" => title,
      "description" => "",
      "updated" => System.system_time(:second),
      "items" => items
    }
    |> then(fn m -> if cont, do: Map.put(m, "continuation", cont), else: m end)
  end

  # Google Reader `ot` = lower bound (unix seconds). `nt` = upper bound.
  # NNW often sends ot ≈ "now" as a watermark; applying that hides all historical
  # unread. Treat ot at/after (now - 5 minutes) as "no lower bound".
  defp apply_time_bounds(query, ot, nt) do
    now = System.system_time(:second)
    ot = normalize_ot(ot, now)
    nt = parse_unix_opt(nt)

    query =
      if ot do
        from([e, s, st] in query,
          where:
            fragment(
              "EXTRACT(EPOCH FROM GREATEST(COALESCE(?, ?), ?)) >= ?",
              e.published_at,
              e.inserted_at,
              e.inserted_at,
              ^ot
            )
        )
      else
        query
      end

    if nt do
      from([e, s, st] in query,
        where:
          fragment(
            "EXTRACT(EPOCH FROM GREATEST(COALESCE(?, ?), ?)) <= ?",
            e.published_at,
            e.inserted_at,
            e.inserted_at,
            ^nt
          )
      )
    else
      query
    end
  end

  defp normalize_ot(nil, _now), do: nil

  defp normalize_ot(ot, now) do
    case parse_unix_opt(ot) do
      nil ->
        nil

      # Future or "essentially now" watermarks empty the stream — ignore.
      t when t >= now - 300 ->
        nil

      t ->
        t
    end
  end

  defp parse_unix_opt(nil), do: nil
  defp parse_unix_opt(""), do: nil
  defp parse_unix_opt(i) when is_integer(i), do: i

  defp parse_unix_opt(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_unix_opt(_), do: nil

  def stream_entry_query(%User{id: user_id} = user, stream_id, opts) do
    exclude_read? = Keyword.get(opts, :exclude_read, false)

    base =
      from(e in Entry,
        join: s in Subscription,
        on: s.feed_id == e.feed_id and s.user_id == ^user_id,
        left_join: st in EntryState,
        on: st.entry_id == e.id and st.user_id == ^user_id,
        where: s.is_hidden == false
      )

    stream_id = Ids.normalize_stream_id(stream_id)

    {base, title} =
      cond do
        Ids.reading_list_stream?(stream_id) ->
          {base, "Reading list"}

        Ids.starred_stream?(stream_id) ->
          {from([e, s, st] in base, where: st.is_star == true), "Starred"}

        Ids.read_stream?(stream_id) ->
          {from([e, s, st] in base, where: st.is_read == true), "Read"}

        String.starts_with?(to_string(stream_id), "feed/") ->
          case feed_from_stream(user, stream_id) do
            %Feed{id: fid, title: t} ->
              {from([e, s, st] in base, where: e.feed_id == ^fid), t || stream_id}

            _ ->
              {from([e, s, st] in base, where: false), stream_id}
          end

        String.contains?(to_string(stream_id), "/label/") ->
          label = Ids.label_from_stream(stream_id)

          case Repo.get_by(Category, user_id: user_id, name: label) do
            %Category{id: cid} ->
              {from([e, s, st] in base, where: s.category_id == ^cid), label}

            _ ->
              {from([e, s, st] in base, where: false), label}
          end

        true ->
          {base, "Reading list"}
      end

    base =
      if exclude_read? do
        from([e, s, st] in base, where: is_nil(st.id) or st.is_read == false)
      else
        base
      end

    {base, title}
  end

  def feed_from_stream(user, "feed/" <> rest) do
    rest = URI.decode(rest)

    case Integer.parse(rest) do
      {id, ""} ->
        # FreshRSS-style stream id: feed/<numeric feed pk>
        if Reader.get_subscription(user, id) do
          Feeds.get_feed(id)
        else
          nil
        end

      _ ->
        # Backward-compat: older clients may still send feed/<url>
        case Feeds.get_feed_by_link(rest) do
          %Feed{} = f ->
            if Reader.get_subscription(user, f.id), do: f, else: nil

          nil ->
            nil
        end
    end
  end

  def feed_from_stream(_, _), do: nil

  defp unix(nil), do: nil
  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp unix(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
end
