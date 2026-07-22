defmodule Earss.GReader do
  @moduledoc """
  Google Reader API subset used by FreshRSS-compatible clients (e.g. NetNewsWire).

  See `docs/greader.md`.
  """

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Reader
  alias Earss.Reader.User
  alias Earss.Reader.Subscription
  alias Earss.Feeds
  alias Earss.Feeds.Entry
  alias Earss.Feeds.Feed
  alias Earss.Reader.EntryState
  alias Earss.Reader.Category

  @salt "earss.greader.auth"
  @edit_salt "earss.greader.edit"

  ## Auth tokens

  def issue_auth(%User{id: id}), do: Plug.Crypto.sign(secret(), @salt, %{uid: id})

  def verify_auth(token) when is_binary(token) do
    max_age =
      Application.get_env(:earss, :api, [])
      |> Keyword.get(:token_max_age_secs, 60 * 60 * 24 * 30)

    user =
      case Plug.Crypto.verify(secret(), @salt, token, max_age: max_age) do
        {:ok, %{uid: uid}} when is_integer(uid) -> Reader.get_user(uid)
        {:ok, %{"uid" => uid}} when is_integer(uid) -> Reader.get_user(uid)
        _ -> nil
      end

    case user do
      %User{is_active: true} = u -> u
      _ -> nil
    end
  end

  def verify_auth(_), do: nil

  def issue_edit_token(%User{id: id}), do: Plug.Crypto.sign(secret(), @edit_salt, %{uid: id})

  def verify_edit_token(%User{id: id}, token) when is_binary(token) do
    case Plug.Crypto.verify(secret(), @edit_salt, token, max_age: 60 * 60 * 24) do
      {:ok, %{uid: ^id}} -> true
      {:ok, %{"uid" => ^id}} -> true
      _ -> match?(%User{}, verify_auth(token))
    end
  end

  def verify_edit_token(_, _), do: false

  defp secret do
    Application.get_env(:earss, :api, [])
    |> Keyword.get(:secret_key_base) ||
      raise "secret_key_base missing"
  end

  ## ClientLogin

  def client_login(email, password) do
    case Reader.authenticate_user(email || "", password || "") do
      {:ok, user} ->
        {:ok, issue_auth(user)}

      {:error, _} ->
        user = Reader.get_user_by_username(email || "")

        if user && user.fever_api_key &&
             user.fever_api_key == Reader.fever_api_key(user.username, password || "") do
          {:ok, issue_auth(user)}
        else
          :error
        end
    end
  end

  ## Subscription list (JSON)

  def subscription_list(%User{} = user) do
    subs = Reader.list_subscriptions(user, include_hidden: false, with_unread_count: true)

    subscriptions =
      Enum.with_index(subs, fn sub, idx ->
        feed = sub.feed
        title = sub.custom_title || feed.title || feed.link

        %{
          "id" => feed_stream_id(feed),
          "title" => title,
          "categories" => feed_categories(sub),
          "url" => feed.link,
          "htmlUrl" => feed.site_url || feed.link,
          "iconUrl" => "",
          "sortid" => sortid(idx + 1)
        }
      end)

    %{"subscriptions" => subscriptions}
  end

  defp feed_categories(%{category: %Category{} = c}) do
    [%{"id" => label_stream_id(c.name), "label" => c.name}]
  end

  defp feed_categories(_), do: []

  ## Tag list

  def tag_list(%User{} = user) do
    cats = Reader.list_categories(user)

    tags =
      [
        %{"id" => "user/-/state/com.google/starred", "sortid" => "A0000001"},
        %{"id" => "user/-/state/com.google/read", "sortid" => "A0000002"}
      ] ++
        Enum.map(Enum.with_index(cats, 3), fn {c, i} ->
          %{
            "id" => label_stream_id(c.name),
            "sortid" => "A" <> String.pad_leading(Integer.to_string(i), 7, "0")
          }
        end)

    %{"tags" => tags}
  end

  ## User info

  def user_info(%User{} = user) do
    %{
      "userId" => to_string(user.id),
      "userName" => user.username,
      "userProfileId" => to_string(user.id),
      "userEmail" => user.username,
      "isBloggerUser" => false,
      "signupTimeSec" => unix(user.inserted_at) || 0,
      "isMultiLoginEnabled" => false
    }
  end

  @doc """
  Unread counts for NetNewsWire / FreshRSS (`reader/api/0/unread-count`).

  Returns per-feed counts, per-label counts, and reading-list total.
  """
  def unread_count(%User{} = user) do
    subs = Reader.list_subscriptions(user, include_hidden: false, with_unread_count: true)
    by_feed = Reader.unread_counts_by_feed(user)

    feed_counts =
      Enum.map(subs, fn sub ->
        count = Map.get(by_feed, sub.feed_id, sub.unread_count || 0)

        %{
          "id" => feed_stream_id(sub.feed),
          "count" => count,
          "newestItemTimestampUsec" => newest_usec(user, sub.feed_id)
        }
      end)

    label_counts =
      subs
      |> Enum.group_by(fn s -> s.category && s.category.name end)
      |> Enum.reject(fn {name, _} -> is_nil(name) end)
      |> Enum.map(fn {name, group_subs} ->
        count =
          group_subs
          |> Enum.map(&Map.get(by_feed, &1.feed_id, &1.unread_count || 0))
          |> Enum.sum()

        %{
          "id" => label_stream_id(name),
          "count" => count,
          "newestItemTimestampUsec" => "0"
        }
      end)

    total =
      feed_counts
      |> Enum.map(& &1["count"])
      |> Enum.sum()

    newest =
      feed_counts
      |> Enum.map(& &1["newestItemTimestampUsec"])
      |> Enum.reject(&(&1 in [nil, "0"]))
      |> Enum.max(fn -> "0" end)

    reading_list_ids = [
      "user/-/state/com.google/reading-list",
      "user/#{user.id}/state/com.google/reading-list"
    ]

    reading_list =
      Enum.map(reading_list_ids, fn id ->
        %{
          "id" => id,
          "count" => total,
          "newestItemTimestampUsec" => newest
        }
      end)

    %{
      "max" => 1000,
      "unreadcounts" => reading_list ++ feed_counts ++ label_counts
    }
  end

  defp newest_usec(%User{id: user_id}, feed_id) do
    # Prefer inserted_at (when we ingested) over publisher's published_at.
    # Feeds often backdate published_at years; NNW may treat that as "no recent items"
    # and show unread 0 even when unread-count is non-zero.
    case from(e in Entry,
           join: s in Subscription,
           on: s.feed_id == e.feed_id and s.user_id == ^user_id,
           left_join: st in EntryState,
           on: st.entry_id == e.id and st.user_id == ^user_id,
           where: e.feed_id == ^feed_id,
           where: is_nil(st.id) or st.is_read == false,
           order_by: [desc: e.inserted_at, desc: e.id],
           limit: 1,
           select: {e.inserted_at, e.published_at}
         )
         |> Repo.one() do
      nil ->
        "0"

      {ins, pub} ->
        dt = later_dt(ins, pub) || ins || pub

        case dt do
          %DateTime{} = d -> "#{DateTime.to_unix(d)}000000"
          _ -> "0"
        end
    end
  end

  defp later_dt(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end

  defp later_dt(%DateTime{} = a, _), do: a
  defp later_dt(_, %DateTime{} = b), do: b
  defp later_dt(_, _), do: nil

  ## Stream item ids

  def stream_item_ids(%User{} = user, stream_id, opts \\ []) do
    n = opts |> Keyword.get(:n, 1000) |> min(10_000)
    xt_read? = Keyword.get(opts, :exclude_read, false)
    continuation = Keyword.get(opts, :continuation)
    ot = Keyword.get(opts, :ot)
    nt = Keyword.get(opts, :nt)

    {query, _} = stream_entry_query(user, stream_id, exclude_read: xt_read?)
    query = apply_time_bounds(query, ot, nt)

    query =
      from([e, s, st] in query,
        order_by: [desc: e.id],
        limit: ^n
      )

    query =
      case parse_continuation(continuation) do
        nil -> query
        cid -> from([e, s, st] in query, where: e.id < ^cid)
      end

    rows =
      Repo.all(
        from([e, s, st] in query,
          select: {e.id, e.published_at, e.inserted_at}
        )
      )

    # NetNewsWire's FreshRSS sync uses decimal item ids in itemRefs (and in i=).
    # Hex-only broke unread assembly on some builds.
    item_refs =
      Enum.map(rows, fn {id, pub, ins} ->
        ts = max(unix(pub) || 0, unix(ins) || 0)

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
    query = apply_time_bounds(query, ot, nt)

    query =
      from([e, s, st] in query,
        order_by: [desc: e.id],
        limit: ^n
      )

    query =
      case parse_continuation(continuation) do
        nil -> query
        cid -> from([e, s, st] in query, where: e.id < ^cid)
      end

    rows =
      Repo.all(
        from([e, s, st] in query,
          select: %{
            entry: e,
            is_read: fragment("coalesce(?, false)", st.is_read),
            is_star: fragment("coalesce(?, false)", st.is_star),
            custom_title: s.custom_title
          }
        )
      )

    items = Enum.map(rows, &entry_item(&1, user))

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

  # Google Reader `ot` = only items at-or-after this unix time (exclude older).
  # `nt` = only items at-or-before this unix time.
  # Use GREATEST(published_at, inserted_at) so newly ingested backdated posts still sync.
  # Ignore absurd future `ot` (NNW sometimes sends a watermark ahead of wall clock).
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

      # Client watermark in the future would hide everything — treat as no lower bound.
      t when t > now + 120 ->
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

  def items_contents(%User{} = user, item_ids) when is_list(item_ids) do
    ids =
      item_ids
      |> Enum.map(&parse_item_id/1)
      |> Enum.reject(&is_nil/1)

    rows =
      if ids == [] do
        []
      else
        from(e in Entry,
          join: s in Subscription,
          on: s.feed_id == e.feed_id and s.user_id == ^user.id,
          left_join: st in EntryState,
          on: st.entry_id == e.id and st.user_id == ^user.id,
          where: e.id in ^ids,
          select: %{
            entry: e,
            is_read: fragment("coalesce(?, false)", st.is_read),
            is_star: fragment("coalesce(?, false)", st.is_star),
            custom_title: s.custom_title
          }
        )
        |> Repo.all()
      end

    %{
      "direction" => "ltr",
      "id" => "user/-/state/com.google/reading-list",
      "title" => "Reading list",
      "items" => Enum.map(rows, &entry_item(&1, user))
    }
  end

  defp entry_item(
         %{entry: e, is_read: is_read, is_star: is_star, custom_title: custom_title},
         user
       ) do
    feed = Feeds.get_feed(e.feed_id)
    feed_title = custom_title || (feed && feed.title) || (feed && feed.link) || ""
    categories = build_item_categories(user, e, is_read, is_star, feed)

    # Crawl time as a floor so clients with "ignore old articles" still see
    # newly ingested posts whose feed published_at is ancient.
    published_unix = unix(e.published_at) || 0
    ingested_unix = unix(e.inserted_at) || 0
    sort_unix = max(published_unix, ingested_unix)

    %{
      "id" => item_atom_id(e.id),
      "categories" => categories,
      "title" => e.title || "",
      "published" => sort_unix,
      "updated" => unix(e.updated_at) || sort_unix,
      "canonical" => [%{"href" => e.link || ""}],
      "alternate" => [%{"href" => e.link || "", "type" => "text/html"}],
      "summary" => %{"content" => e.content || e.summary || "", "direction" => "ltr"},
      "author" => e.author || "",
      "origin" => %{
        "streamId" => if(feed, do: feed_stream_id(feed), else: ""),
        "title" => feed_title,
        "htmlUrl" => (feed && (feed.site_url || feed.link)) || ""
      },
      "timestampUsec" => "#{sort_unix}000000"
    }
  end

  defp build_item_categories(user, _entry, is_read, is_star, feed) do
    base = ["user/-/state/com.google/reading-list"]
    base = if is_read, do: ["user/-/state/com.google/read" | base], else: base
    base = if is_star, do: ["user/-/state/com.google/starred" | base], else: base
    base = if feed, do: [feed_stream_id(feed) | base], else: base

    sub = feed && Reader.get_subscription(user, feed.id)
    sub = sub && Repo.preload(sub, :category)

    case sub do
      %{category: %{name: name}} when is_binary(name) ->
        [label_stream_id(name) | base]

      _ ->
        base
    end
  end

  ## edit-tag

  def edit_tag(%User{} = user, item_ids, add, remove) do
    ids =
      item_ids
      |> List.wrap()
      |> Enum.map(&parse_item_id/1)
      |> Enum.reject(&is_nil/1)

    add = List.wrap(add)
    remove = List.wrap(remove)

    Enum.each(ids, fn id ->
      cond do
        Enum.any?(add, &read_state?/1) -> Reader.mark_read(user, id)
        Enum.any?(remove, &read_state?/1) -> Reader.mark_unread(user, id)
        true -> :ok
      end

      cond do
        Enum.any?(add, &star_state?/1) -> Reader.set_star(user, id, true)
        Enum.any?(remove, &star_state?/1) -> Reader.set_star(user, id, false)
        true -> :ok
      end
    end)

    :ok
  end

  defp read_state?(s), do: String.contains?(to_string(s), "state/com.google/read")
  defp star_state?(s), do: String.contains?(to_string(s), "state/com.google/starred")

  ## mark-all-as-read

  def mark_all_as_read(%User{} = user, stream_id, _timestamp_sec \\ nil) do
    stream_id = normalize_stream_id(stream_id)

    cond do
      stream_id in [nil, "", "user/-/state/com.google/reading-list"] ->
        Reader.mark_entries_read(user, category_id: 0)

      String.starts_with?(to_string(stream_id), "feed/") ->
        case feed_from_stream(user, stream_id) do
          %Feed{id: id} -> Reader.mark_entries_read(user, feed_id: id)
          _ -> {:ok, %{marked: 0}}
        end

      String.contains?(to_string(stream_id), "/label/") ->
        label = label_from_stream(stream_id)

        case Repo.get_by(Category, user_id: user.id, name: label) do
          %Category{id: id} -> Reader.mark_entries_read(user, category_id: id)
          _ -> {:ok, %{marked: 0}}
        end

      true ->
        {:ok, %{marked: 0}}
    end
  end

  ## Stream query builder

  defp stream_entry_query(%User{id: user_id} = user, stream_id, opts) do
    exclude_read? = Keyword.get(opts, :exclude_read, false)

    base =
      from(e in Entry,
        join: s in Subscription,
        on: s.feed_id == e.feed_id and s.user_id == ^user_id,
        left_join: st in EntryState,
        on: st.entry_id == e.id and st.user_id == ^user_id,
        where: s.is_hidden == false
      )

    stream_id = normalize_stream_id(stream_id)

    {base, title} =
      cond do
        stream_id in [nil, "", "user/-/state/com.google/reading-list"] ->
          {base, "Reading list"}

        stream_id == "user/-/state/com.google/starred" ->
          {from([e, s, st] in base, where: st.is_star == true), "Starred"}

        stream_id == "user/-/state/com.google/read" ->
          {from([e, s, st] in base, where: st.is_read == true), "Read"}

        String.starts_with?(to_string(stream_id), "feed/") ->
          case feed_from_stream(user, stream_id) do
            %Feed{id: fid, title: t} ->
              {from([e, s, st] in base, where: e.feed_id == ^fid), t || stream_id}

            _ ->
              {from([e, s, st] in base, where: false), stream_id}
          end

        String.contains?(to_string(stream_id), "/label/") ->
          label = label_from_stream(stream_id)

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

  defp feed_from_stream(user, "feed/" <> rest) do
    url = URI.decode(rest)

    case Integer.parse(url) do
      {id, ""} ->
        case Reader.get_subscription(user, id) do
          %{feed: %Feed{} = feed} -> feed
          %{feed_id: ^id} -> Feeds.get_feed(id)
          _ -> nil
        end

      _ ->
        case Feeds.get_feed_by_link(url) || Feeds.get_feed_by_link(rest) do
          %Feed{} = f ->
            if Reader.get_subscription(user, f.id), do: f, else: nil

          nil ->
            nil
        end
    end
  end

  defp feed_from_stream(_, _), do: nil

  ## ID helpers

  def feed_stream_id(%Feed{link: link, id: id}) do
    "feed/#{link || id}"
  end

  def label_stream_id(name), do: "user/-/label/#{name}"

  def item_hex_id(id) when is_integer(id) do
    id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")
  end

  def item_atom_id(id) when is_integer(id) do
    "tag:google.com,2005:reader/item/#{item_hex_id(id)}"
  end

  def parse_item_id(nil), do: nil
  def parse_item_id(id) when is_integer(id), do: id

  def parse_item_id(str) when is_binary(str) do
    str = String.trim(str)

    cond do
      String.contains?(str, "/item/") ->
        hex = str |> String.split("/item/") |> List.last() |> String.trim()
        parse_hex_or_dec(hex)

      true ->
        parse_hex_or_dec(str)
    end
  end

  defp parse_hex_or_dec(str) do
    # Prefer hex when it looks like hex (contains a-f or is zero-padded)
    cond do
      String.match?(str, ~r/^[0-9a-fA-F]+$/) and
          (String.match?(str, ~r/[a-fA-F]/) or String.length(str) >= 8) ->
        case Integer.parse(str, 16) do
          {i, _} -> i
          :error -> nil
        end

      match?({_, _}, Integer.parse(str)) ->
        {i, _} = Integer.parse(str)
        i

      String.match?(str, ~r/^[0-9a-fA-F]+$/) ->
        case Integer.parse(str, 16) do
          {i, _} -> i
          :error -> nil
        end

      true ->
        nil
    end
  end

  defp sortid(n) when is_integer(n) do
    n
    |> Integer.to_string(16)
    |> String.upcase()
    |> String.pad_leading(8, "0")
  end

  defp parse_continuation(nil), do: nil
  defp parse_continuation(""), do: nil

  defp parse_continuation(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_continuation(i) when is_integer(i), do: i
  defp parse_continuation(_), do: nil

  defp label_from_stream(stream_id) do
    stream_id
    |> String.split("/label/")
    |> List.last()
    |> URI.decode()
  end

  defp normalize_stream_id(nil), do: nil

  defp normalize_stream_id(stream_id) when is_binary(stream_id) do
    stream_id
    |> URI.decode()
    |> String.replace(~r{^user/\d+/}, "user/-/")
  end

  defp normalize_stream_id(other), do: other

  defp unix(nil), do: nil
  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp unix(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
end
