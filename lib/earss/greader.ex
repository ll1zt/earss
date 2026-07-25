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

    # Match FreshRSS: system tags first, then folders with type=folder.
    # NNW FreshRSS accounts create sidebar folders from tags containing "/label/".
    tags =
      [
        %{"id" => "user/-/state/com.google/starred"},
        %{"id" => "user/-/state/com.google/reading-list"}
      ] ++
        Enum.map(cats, fn c ->
          %{
            "id" => label_stream_id(c.name),
            "type" => "folder"
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

    # NetNewsWire posts contents with decimal i= values.
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
      case parse_continuation(continuation) do
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
          select: %{
            entry: e,
            feed: f,
            is_read: fragment("coalesce(?, false)", st.is_read),
            is_star: fragment("coalesce(?, false)", st.is_star),
            custom_title: s.custom_title,
            category_name: c.name
          }
        )
      )

    items = Enum.map(rows, &entry_item/1)

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
          join: f in Feed,
          on: f.id == e.feed_id,
          left_join: st in EntryState,
          on: st.entry_id == e.id and st.user_id == ^user.id,
          left_join: c in Category,
          on: c.id == s.category_id,
          where: e.id in ^ids,
          select: %{
            entry: e,
            feed: f,
            is_read: fragment("coalesce(?, false)", st.is_read),
            is_star: fragment("coalesce(?, false)", st.is_star),
            custom_title: s.custom_title,
            category_name: c.name
          }
        )
        |> Repo.all()
      end

    # NetNewsWire decodes this as ReaderAPIEntryWrapper which REQUIRES `updated`.
    # Missing that field makes the whole contents response fail to decode, so
    # articles never land locally → unread counts stay 0 → "Hide Read Feeds"
    # empties the sidebar even though subscription/list returned feeds.
    %{
      "direction" => "ltr",
      "id" => "user/-/state/com.google/reading-list",
      "title" => "Reading list",
      "description" => "",
      "updated" => System.system_time(:second),
      "items" => Enum.map(rows, &entry_item/1)
    }
  end

  defp entry_item(%{
         entry: e,
         is_read: is_read,
         is_star: is_star,
         custom_title: custom_title
       } = row) do
    feed = Map.get(row, :feed) || Feeds.get_feed(e.feed_id)
    category_name = Map.get(row, :category_name)
    feed_title = custom_title || (feed && feed.title) || (feed && feed.link) || ""
    categories = build_item_categories(is_read, is_star, feed, category_name)

    # Crawl time as a floor so clients with "ignore old articles" still see
    # newly ingested posts whose feed published_at is ancient.
    published_unix = unix(e.published_at) || 0
    ingested_unix = unix(e.inserted_at) || 0
    sort_unix = max(published_unix, ingested_unix)
    crawl_msec = max(ingested_unix, published_unix) * 1000

    %{
      "id" => item_atom_id(e.id),
      "categories" => categories,
      "title" => e.title || "",
      "published" => sort_unix,
      "updated" => unix(e.updated_at) || sort_unix,
      "crawlTimeMsec" => Integer.to_string(crawl_msec),
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

  defp build_item_categories(is_read, is_star, feed, category_name) do
    base = ["user/-/state/com.google/reading-list"]
    base = if is_read, do: ["user/-/state/com.google/read" | base], else: base
    base = if is_star, do: ["user/-/state/com.google/starred" | base], else: base
    base = if feed, do: [feed_stream_id(feed) | base], else: base

    if is_binary(category_name) and category_name != "" do
      [label_stream_id(category_name) | base]
    else
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
      reading_list_stream?(stream_id) ->
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
        reading_list_stream?(stream_id) ->
          {base, "Reading list"}

        starred_stream?(stream_id) ->
          {from([e, s, st] in base, where: st.is_star == true), "Starred"}

        read_stream?(stream_id) ->
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

  defp feed_from_stream(_, _), do: nil

  ## ID helpers

  # FreshRSS / NetNewsWire use numeric feed stream ids (`feed/42`), not the feed URL.
  def feed_stream_id(%Feed{id: id}), do: "feed/#{id}"

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
      # NetNewsWire posts contents/edit-tag as:
      #   i=tag:google.com,2005:reader/item/<unpadded-hex>
      # e.g. entry 51 → ".../item/33". This MUST be parsed as hex, not decimal.
      String.contains?(str, "/item/") ->
        hex = str |> String.split("/item/") |> List.last() |> String.trim()
        parse_hex(hex)

      true ->
        parse_hex_or_dec(str)
    end
  end

  defp parse_hex(str) when is_binary(str) do
    if String.match?(str, ~r/^[0-9a-fA-F]+$/) do
      case Integer.parse(str, 16) do
        {i, _} -> i
        :error -> nil
      end
    else
      nil
    end
  end

  defp parse_hex_or_dec(str) do
    # Bare ids: hex if it has a-f or is zero-padded/long (GReader style),
    # otherwise decimal (itemRefs use decimal strings like "51").
    cond do
      String.match?(str, ~r/^[0-9a-fA-F]+$/) and
          (String.match?(str, ~r/[a-fA-F]/) or String.starts_with?(str, "0") or
             String.length(str) >= 8) ->
        parse_hex(str)

      match?({_, _}, Integer.parse(str)) ->
        {i, _} = Integer.parse(str)
        i

      String.match?(str, ~r/^[0-9a-fA-F]+$/) ->
        parse_hex(str)

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

  def normalize_stream_id(nil), do: nil

  def normalize_stream_id(stream_id) when is_binary(stream_id) do
    stream_id
    |> URI.decode()
    |> String.trim()
    |> String.trim_leading("/")
    |> String.replace(~r{^user/\d+/}, "user/-/")
    |> expand_short_stream_id()
  end

  def normalize_stream_id(other), do: other

  # FreshRSS examples and some clients use bare suffixes:
  #   stream/contents/reading-list, stream/contents/starred
  defp expand_short_stream_id("reading-list"),
    do: "user/-/state/com.google/reading-list"

  defp expand_short_stream_id("starred"), do: "user/-/state/com.google/starred"
  defp expand_short_stream_id("read"), do: "user/-/state/com.google/read"
  defp expand_short_stream_id(other), do: other

  defp reading_list_stream?(stream_id) do
    stream_id in [nil, "", "user/-/state/com.google/reading-list", "reading-list"]
  end

  defp starred_stream?(stream_id),
    do: stream_id in ["user/-/state/com.google/starred", "starred"]

  defp read_stream?(stream_id),
    do: stream_id in ["user/-/state/com.google/read", "read"]

  @doc """
  Minimal FreshRSS-compatible subscription/edit.

  Actions (`ac`):
    * `subscribe` / `edit` — subscribe or update (`s=feed/<url|id>`, optional `t` title, `a=user/-/label/Name`)
    * `unsubscribe` — drop subscription for `s=feed/<id|url>`
  """
  def subscription_edit(%User{} = user, params) when is_map(params) do
    params = stringify_param_keys(params)
    ac = params["ac"] || params["action"] || ""
    stream = params["s"]
    title = blank_to_nil(params["t"])
    add_label = params["a"]
    remove_label = params["r"]

    case ac do
      "subscribe" ->
        do_subscribe_edit(user, stream, title, add_label)

      "edit" ->
        do_edit_subscription(user, stream, title, add_label, remove_label)

      "unsubscribe" ->
        do_unsubscribe(user, stream)

      _ ->
        {:error, :bad_request}
    end
  end

  defp do_subscribe_edit(user, stream, title, add_label) do
    with {:ok, attrs} <- subscribe_attrs_from_stream(user, stream, title, add_label) do
      # Queue via next_fetch_at; avoid blocking the HTTP request on a live crawl.
      case Reader.subscribe(user, Map.put(attrs, "refresh", false)) do
        {:ok, _} -> :ok
        {:error, %Ecto.Changeset{}} = err -> err
        {:error, :not_found} -> {:error, :not_found}
        {:error, _} = err -> err
      end
    end
  end

  defp do_edit_subscription(user, stream, title, add_label, remove_label) do
    case feed_from_stream(user, normalize_feed_stream(stream)) do
      %Feed{id: feed_id} ->
        case Reader.get_subscription(user, feed_id) do
          %Subscription{} = sub ->
            attrs = %{}
            attrs = if title, do: Map.put(attrs, "custom_title", title), else: attrs

            attrs =
              cond do
                is_binary(add_label) and String.contains?(add_label, "/label/") ->
                  label = label_from_stream(add_label)

                  case ensure_category(user, label) do
                    {:ok, %Category{id: cid}} -> Map.put(attrs, "category_id", cid)
                    _ -> attrs
                  end

                is_binary(remove_label) and String.contains?(remove_label, "/label/") ->
                  Map.put(attrs, "category_id", nil)

                true ->
                  attrs
              end

            case Reader.update_subscription(sub, attrs) do
              {:ok, _} -> :ok
              error -> error
            end

          nil ->
            # FreshRSS clients sometimes use edit as upsert subscribe.
            do_subscribe_edit(user, stream, title, add_label)
        end

      nil ->
        do_subscribe_edit(user, stream, title, add_label)
    end
  end

  defp do_unsubscribe(user, stream) do
    stream = normalize_feed_stream(stream)

    feed_id =
      case feed_from_stream(user, stream) do
        %Feed{id: id} ->
          id

        nil ->
          case stream do
            "feed/" <> rest ->
              rest = URI.decode(rest)

              case Integer.parse(rest) do
                {id, ""} -> id
                _ -> Feeds.get_feed_by_link(rest) && Feeds.get_feed_by_link(rest).id
              end

            _ ->
              nil
          end
      end

    if feed_id do
      case Reader.unsubscribe(user, feed_id) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        error -> error
      end
    else
      {:error, :not_found}
    end
  end

  defp subscribe_attrs_from_stream(user, stream, title, add_label) do
    stream = normalize_feed_stream(stream)

    base =
      case stream do
        "feed/" <> rest ->
          rest = URI.decode(rest)

          case Integer.parse(rest) do
            {id, ""} ->
              %{"feed_id" => id}

            _ ->
              %{"link" => rest}
          end

        other when is_binary(other) and other != "" ->
          %{"link" => other}

        _ ->
          nil
      end

    cond do
      is_nil(base) ->
        {:error, :bad_request}

      true ->
        attrs = maybe_put_title(base, title)

        attrs =
          case category_id_from_label(user, add_label) do
            {:ok, cid} -> Map.put(attrs, "category_id", cid)
            :none -> attrs
            {:error, _} = err -> err
          end

        case attrs do
          {:error, _} = err -> err
          map when is_map(map) -> {:ok, map}
        end
    end
  end

  defp maybe_put_title(attrs, nil), do: attrs

  defp maybe_put_title(attrs, title) do
    attrs
    |> Map.put("title", title)
    |> Map.put("custom_title", title)
  end

  defp category_id_from_label(_user, label) when label in [nil, ""], do: :none

  defp category_id_from_label(user, label) when is_binary(label) do
    if String.contains?(label, "/label/") do
      name = label_from_stream(label)

      case ensure_category(user, name) do
        {:ok, %Category{id: cid}} -> {:ok, cid}
        {:error, _} = err -> err
      end
    else
      :none
    end
  end

  defp category_id_from_label(_, _), do: :none

  defp normalize_feed_stream(nil), do: nil

  defp normalize_feed_stream(stream) when is_binary(stream) do
    stream = stream |> URI.decode() |> String.trim()

    cond do
      String.starts_with?(stream, "feed/") -> stream
      String.match?(stream, ~r{^https?://}i) -> "feed/#{stream}"
      true -> stream
    end
  end

  defp ensure_category(%User{} = user, name) when is_binary(name) do
    name = String.trim(name)

    case Enum.find(Reader.list_categories(user), &(&1.name == name)) do
      %Category{} = c ->
        {:ok, c}

      nil ->
        Reader.create_category(user, %{name: name})
    end
  end

  defp stringify_param_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp unix(nil), do: nil
  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp unix(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
end
