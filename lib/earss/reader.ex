defmodule Earss.Reader do
  @moduledoc """
  The Reader context.

  Users, categories, subscriptions, reading state, and per-user timelines.
  Lifecycle side effects follow `docs/data_lifecycle.md`.
  """

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.Feed
  alias Earss.Feeds.Entry
  alias Earss.Reader.User
  alias Earss.Reader.Category
  alias Earss.Reader.Subscription
  alias Earss.Reader.EntryState
  alias Earss.Reader.OPML

  ## Users

  def create_sub_user(username, password), do: create_user(username, password, "sub_user")

  def create_user(username, password, user_type \\ "admin") do
    username = String.trim(username)

    %{
      username: username,
      password_hash: Argon2.hash_pwd_salt(password),
      user_type: user_type,
      fever_api_key: fever_api_key(username, password)
    }
    |> do_create_user()
  end

  defp do_create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  def get_user_by_fever_api_key(api_key) when is_binary(api_key) do
    key = String.downcase(String.trim(api_key))

    case Repo.get_by(User, fever_api_key: key) do
      %User{is_active: true} = user -> user
      _ -> nil
    end
  end

  def get_user_by_fever_api_key(_), do: nil

  def authenticate_user(username, password) do
    user = Repo.get_by(User, username: username)

    cond do
      user && user.is_active && Argon2.verify_pass(password, user.password_hash) ->
        {:ok, user}

      user && not user.is_active ->
        Argon2.no_user_verify()
        {:error, :unauthorized}

      user ->
        {:error, :unauthorized}

      true ->
        Argon2.no_user_verify()
        {:error, :not_found}
    end
  end

  @doc """
  Update login password and recompute Fever api_key from the new password.
  """
  def set_password(%User{} = user, password) when is_binary(password) do
    user
    |> User.changeset(%{
      password_hash: Argon2.hash_pwd_salt(password),
      fever_api_key: fever_api_key(user.username, password)
    })
    |> Repo.update()
  end

  @doc """
  Set a Fever-only secret (does not change login password).

  Clients compute api_key = md5(username <> \":\" <> secret).
  """
  def set_fever_password(%User{} = user, secret) when is_binary(secret) do
    user
    |> User.changeset(%{fever_api_key: fever_api_key(user.username, secret)})
    |> Repo.update()
  end

  @doc """
  Fever api_key = lowercase hex md5(username || \":\" || secret).
  """
  def fever_api_key(username, secret)
      when is_binary(username) and is_binary(secret) do
    :crypto.hash(:md5, "#{username}:#{secret}") |> Base.encode16(case: :lower)
  end

  @doc """
  Soft-disable a user (`is_active = false`). Auth will fail afterwards.
  """
  def deactivate_user(%User{} = user) do
    user
    |> User.changeset(%{is_active: false})
    |> Repo.update()
  end

  def delete_user(username, password) do
    case authenticate_user(username, password) do
      {:ok, user} -> do_delete_user(user)
      error -> error
    end
  end

  def delete_user(admin_username, admin_password, sub_user_username) do
    case authenticate_user(admin_username, admin_password) do
      {:ok, %{user_type: "admin"}} ->
        case Repo.get_by(User, username: sub_user_username) do
          nil -> {:error, :not_found}
          target_user -> do_delete_user(target_user)
        end

      {:ok, _not_admin} ->
        {:error, :unauthorized}

      error ->
        error
    end
  end

  defp do_delete_user(%User{} = user) do
    feed_ids =
      Subscription
      |> where([s], s.user_id == ^user.id)
      |> select([s], s.feed_id)
      |> Repo.all()

    Repo.transaction(fn ->
      case Repo.delete(user) do
        {:ok, user} ->
          Enum.each(feed_ids, &maybe_mark_feed_unsubscribed/1)
          user

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  ## Categories

  def list_categories(%User{id: user_id}) do
    Category
    |> where([c], c.user_id == ^user_id)
    |> order_by([c], asc: c.position, asc: c.id)
    |> Repo.all()
  end

  def get_category(id), do: Repo.get(Category, id)

  def create_category(%User{id: user_id}, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("user_id", user_id)

    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert()
  end

  def update_category(%Category{} = category, attrs) when is_map(attrs) do
    category
    |> Category.changeset(stringify_keys(attrs))
    |> Repo.update()
  end

  def delete_category(%Category{} = category), do: Repo.delete(category)

  ## Subscriptions

  @doc """
  Subscribe a user to a feed URL (or existing feed id).

  Options / attrs:
    * `:feed_id` — subscribe to existing feed (skips ensure_feed)
    * `:link` — feed URL (ensure_feed)
    * `:title` — used only when creating a new feed
    * `:category_id`, `:custom_title`, `:custom_refresh_interval`, `:is_hidden`
    * `:refresh` — when true (default), call `Feeds.refresh/1` after subscribe
  """
  def subscribe(%User{} = user, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    refresh? = Map.get(attrs, "refresh", true)

    result =
      Repo.transaction(fn ->
        with {:ok, feed} <- resolve_feed_for_subscribe(attrs),
             {:ok, subscription} <- insert_subscription(user, feed, attrs),
             {:ok, feed} <- clear_unsubscribed_and_queue(feed) do
          {subscription, feed}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {subscription, feed}} ->
        # HTTP refresh must not run inside the DB transaction.
        if refresh? do
          _ = Feeds.refresh(feed)
        end

        {:ok, Repo.preload(subscription, [:feed, :category], force: true)}

      {:error, _} = error ->
        error
    end
  end

  def unsubscribe(%User{id: user_id}, feed_id) when not is_nil(feed_id) do
    case Repo.get_by(Subscription, user_id: user_id, feed_id: feed_id) do
      nil ->
        {:error, :not_found}

      %Subscription{} = sub ->
        Repo.transaction(fn ->
          delete_entry_states_for_user_feed(user_id, feed_id)

          case Repo.delete(sub) do
            {:ok, sub} ->
              maybe_mark_feed_unsubscribed(feed_id)
              sub

            {:error, cs} ->
              Repo.rollback(cs)
          end
        end)
    end
  end

  def get_subscription(%User{id: user_id}, feed_id) do
    Repo.get_by(Subscription, user_id: user_id, feed_id: feed_id)
  end

  def list_subscriptions(%User{id: user_id} = user, opts \\ []) do
    include_hidden? = Keyword.get(opts, :include_hidden, true)
    with_unread? = Keyword.get(opts, :with_unread_count, false)

    query =
      Subscription
      |> where([s], s.user_id == ^user_id)
      |> order_by([s], asc: s.id)
      |> preload([:feed, :category])

    query =
      if include_hidden? do
        query
      else
        where(query, [s], s.is_hidden == false)
      end

    subs = Repo.all(query)

    if with_unread? do
      counts = unread_counts_by_feed(user)

      Enum.map(subs, fn sub ->
        %{sub | unread_count: Map.get(counts, sub.feed_id, 0)}
      end)
    else
      subs
    end
  end

  @doc """
  Map of `feed_id => unread_count` for the user across all subscriptions.
  """
  def unread_counts_by_feed(%User{id: user_id}) do
    from(e in Entry,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id,
      left_join: st in EntryState,
      on: st.entry_id == e.id and st.user_id == ^user_id,
      where: is_nil(st.id) or st.is_read == false,
      group_by: e.feed_id,
      select: {e.feed_id, count(e.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  def update_subscription(%Subscription{} = subscription, attrs) when is_map(attrs) do
    subscription
    |> Subscription.changeset(stringify_keys(attrs))
    |> Repo.update()
    |> case do
      {:ok, sub} -> {:ok, Repo.preload(sub, [:feed, :category], force: true)}
      error -> error
    end
  end

  def hide_subscription(%Subscription{} = sub), do: update_subscription(sub, %{is_hidden: true})

  def unhide_subscription(%Subscription{} = sub),
    do: update_subscription(sub, %{is_hidden: false})

  ## Entry states (lazy)

  def mark_read(%User{id: user_id}, entry_id),
    do: upsert_state(user_id, entry_id, %{is_read: true})

  def mark_unread(%User{id: user_id}, entry_id),
    do: upsert_state(user_id, entry_id, %{is_read: false, read_at: nil})

  def set_star(%User{id: user_id}, entry_id, starred?) when is_boolean(starred?) do
    upsert_state(user_id, entry_id, %{is_star: starred?})
  end

  def get_entry_state(%User{id: user_id}, entry_id) do
    Repo.get_by(EntryState, user_id: user_id, entry_id: entry_id)
  end

  @doc """
  Mark many entries read.

  Options:
    * `:ids` — list of entry ids
    * `:feed_id` — all entries of a subscribed feed for this user
  """
  def mark_entries_read(%User{} = user, opts) when is_list(opts) or is_map(opts) do
    opts = Map.new(opts)
    ids = Map.get(opts, :ids) || Map.get(opts, "ids")
    feed_id = Map.get(opts, :feed_id) || Map.get(opts, "feed_id")
    category_id = Map.get(opts, :category_id) || Map.get(opts, "category_id")
    before_ts = Map.get(opts, :before) || Map.get(opts, "before")

    entry_ids =
      cond do
        is_list(ids) and ids != [] ->
          Enum.map(ids, &normalize_id/1) |> Enum.reject(&is_nil/1)

        feed_id ->
          feed_id = normalize_id(feed_id)

          case get_subscription(user, feed_id) do
            nil ->
              :not_subscribed

            _ ->
              Entry
              |> where([e], e.feed_id == ^feed_id)
              |> maybe_filter_before(before_ts)
              |> select([e], e.id)
              |> Repo.all()
          end

        category_id == 0 or category_id == "0" ->
          # Fever group 0: treat as all subscribed entries
          entry_ids_for_user(user, before_ts)

        category_id ->
          category_id = normalize_id(category_id)

          feed_ids =
            Subscription
            |> where([s], s.user_id == ^user.id and s.category_id == ^category_id)
            |> select([s], s.feed_id)
            |> Repo.all()

          Entry
          |> where([e], e.feed_id in ^feed_ids)
          |> maybe_filter_before(before_ts)
          |> select([e], e.id)
          |> Repo.all()

        true ->
          []
      end

    case entry_ids do
      :not_subscribed ->
        {:error, :not_found}

      [] ->
        {:ok, %{marked: 0}}

      entry_ids ->
        marked =
          Enum.reduce(entry_ids, 0, fn id, acc ->
            case mark_read(user, id) do
              {:ok, _} -> acc + 1
              {:error, _} -> acc
            end
          end)

        {:ok, %{marked: marked}}
    end
  end

  ## OPML

  @doc """
  Import OPML for a user. Creates categories by outline folders when present.

  Options:
    * `:refresh` — default `false` (let poller fetch)
  """
  def import_opml(%User{} = user, xml, opts \\ []) when is_binary(xml) do
    refresh? = Keyword.get(opts, :refresh, false)

    case OPML.parse(xml) do
      {:error, reason} ->
        {:error, reason}

      {:ok, items} ->
        results =
          Enum.map(items, fn item ->
            category_id =
              case item.category do
                nil ->
                  nil

                name ->
                  case ensure_category(user, name) do
                    {:ok, cat} -> cat.id
                    _ -> nil
                  end
              end

            attrs = %{
              "link" => item.link,
              "title" => item.title,
              "category_id" => category_id,
              "refresh" => refresh?
            }

            case subscribe(user, attrs) do
              {:ok, sub} -> {:ok, sub}
              {:error, %Ecto.Changeset{}} -> {:skipped, :already_subscribed}
              {:error, reason} -> {:error, reason}
            end
          end)

        %{
          total: length(items),
          imported: Enum.count(results, &match?({:ok, _}, &1)),
          skipped: Enum.count(results, &match?({:skipped, _}, &1)),
          errors: Enum.count(results, &match?({:error, _}, &1))
        }
        |> then(&{:ok, &1})
    end
  end

  @doc """
  Export the user's subscriptions as OPML XML.
  """
  def export_opml(%User{} = user, opts \\ []) do
    include_hidden? = Keyword.get(opts, :include_hidden, false)

    items =
      user
      |> list_subscriptions(include_hidden: include_hidden?)
      |> Enum.map(fn sub ->
        title = sub.custom_title || (sub.feed && sub.feed.title) || sub.feed.link
        category = if sub.category, do: sub.category.name, else: nil

        %{
          title: title,
          link: sub.feed.link,
          site_url: sub.feed.site_url,
          category: category
        }
      end)

    {:ok, OPML.export(items, "#{user.username} subscriptions")}
  end

  defp ensure_category(%User{} = user, name) when is_binary(name) do
    name = String.trim(name)

    case Repo.get_by(Category, user_id: user.id, name: name) do
      %Category{} = cat -> {:ok, cat}
      nil -> create_category(user, %{name: name})
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp normalize_id(_), do: nil

  defp entry_ids_for_user(%User{id: user_id}, before_ts) do
    from(e in Entry,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id,
      select: e.id
    )
    |> maybe_filter_before(before_ts)
    |> Repo.all()
  end

  defp maybe_filter_before(query, nil), do: query
  defp maybe_filter_before(query, ""), do: query

  defp maybe_filter_before(query, ts) do
    case normalize_unix(ts) do
      nil ->
        query

      unix ->
        dt = DateTime.from_unix!(unix) |> DateTime.truncate(:second)
        from(e in query, where: e.published_at <= ^dt or is_nil(e.published_at))
    end
  end

  defp normalize_unix(ts) when is_integer(ts), do: ts

  defp normalize_unix(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp normalize_unix(_), do: nil

  ## Fever helpers

  @doc """
  Unread entry ids for Fever (newest last / ascending id).
  """
  def list_unread_entry_ids(%User{id: user_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50_000)

    from(e in Entry,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id,
      left_join: st in EntryState,
      on: st.entry_id == e.id and st.user_id == ^user_id,
      where: is_nil(st.id) or st.is_read == false,
      where: s.is_hidden == false,
      order_by: [asc: e.id],
      limit: ^limit,
      select: e.id
    )
    |> Repo.all()
  end

  @doc """
  Starred entry ids for Fever.
  """
  def list_starred_entry_ids(%User{id: user_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50_000)

    from(st in EntryState,
      join: e in Entry,
      on: e.id == st.entry_id,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id,
      where: st.user_id == ^user_id and st.is_star == true,
      order_by: [asc: e.id],
      limit: ^limit,
      select: e.id
    )
    |> Repo.all()
  end

  @doc """
  Total entry count visible to the user via non-hidden subscriptions (Fever `total_items`).
  """
  def count_fever_items(%User{id: user_id}) do
    from(e in Entry,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id,
      where: s.is_hidden == false,
      select: count(e.id)
    )
    |> Repo.one() || 0
  end

  @doc """
  Entries for Fever items endpoint (ordered by id ascending).
  """
  def list_fever_items(%User{id: user_id}, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(50)
    since_id = Keyword.get(opts, :since_id)
    max_id = Keyword.get(opts, :max_id)
    with_ids = Keyword.get(opts, :with_ids) || []

    ids =
      with_ids
      |> Enum.map(&normalize_id/1)
      |> Enum.reject(&is_nil/1)

    query =
      from(e in Entry,
        join: s in Subscription,
        on: s.feed_id == e.feed_id and s.user_id == ^user_id,
        left_join: st in EntryState,
        on: st.entry_id == e.id and st.user_id == ^user_id,
        where: s.is_hidden == false,
        select: %{
          entry: e,
          is_read: fragment("coalesce(?, false)", st.is_read),
          is_star: fragment("coalesce(?, false)", st.is_star)
        }
      )

    {query, reverse?} =
      cond do
        ids != [] ->
          {from([e, s, st] in query, where: e.id in ^ids, order_by: [asc: e.id]), false}

        is_integer(max_id) ->
          {from([e, s, st] in query,
             where: e.id < ^max_id,
             order_by: [desc: e.id],
             limit: ^limit
           ), true}

        is_integer(since_id) and since_id > 0 ->
          {from([e, s, st] in query,
             where: e.id > ^since_id,
             order_by: [asc: e.id],
             limit: ^limit
           ), false}

        true ->
          {from([e, s, st] in query, order_by: [asc: e.id], limit: ^limit), false}
      end

    rows = Repo.all(query)
    if reverse?, do: Enum.reverse(rows), else: rows
  end

  ## Timeline

  @doc """
  List entries visible to the user via subscriptions.

  Options:
    * `:limit` / `:offset`
    * `:feed_id` — single feed
    * `:category_id` — subscriptions in category (`:none` for uncategorized)
    * `:unread_only` — true filters to unread (no state or is_read=false)
    * `:starred_only` — true filters to starred
    * `:include_hidden` — include hidden subscriptions (default false)
  """
  def list_entries(%User{id: user_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    include_hidden? = Keyword.get(opts, :include_hidden, false)

    query =
      from(e in Entry,
        join: s in Subscription,
        on: s.feed_id == e.feed_id and s.user_id == ^user_id,
        left_join: st in EntryState,
        on: st.entry_id == e.id and st.user_id == ^user_id,
        order_by: [desc_nulls_last: e.published_at, desc: e.id],
        limit: ^limit,
        offset: ^offset,
        select: %{
          entry: e,
          is_read: fragment("coalesce(?, false)", st.is_read),
          is_star: fragment("coalesce(?, false)", st.is_star),
          subscription_id: s.id,
          custom_title: s.custom_title
        }
      )

    query =
      if include_hidden? do
        query
      else
        from([e, s, st] in query, where: s.is_hidden == false)
      end

    query =
      case Keyword.get(opts, :feed_id) do
        nil -> query
        feed_id -> from([e, s, st] in query, where: e.feed_id == ^feed_id)
      end

    query =
      case Keyword.get(opts, :category_id) do
        nil ->
          query

        :none ->
          from([e, s, st] in query, where: is_nil(s.category_id))

        category_id ->
          from([e, s, st] in query, where: s.category_id == ^category_id)
      end

    query =
      if Keyword.get(opts, :unread_only, false) do
        from([e, s, st] in query, where: is_nil(st.id) or st.is_read == false)
      else
        query
      end

    query =
      if Keyword.get(opts, :starred_only, false) do
        from([e, s, st] in query, where: st.is_star == true)
      else
        query
      end

    Repo.all(query)
  end

  ## Internal — subscriptions

  defp resolve_feed_for_subscribe(attrs) do
    cond do
      feed_id = Map.get(attrs, "feed_id") ->
        case Feeds.get_feed(feed_id) do
          nil -> {:error, :feed_not_found}
          feed -> {:ok, feed}
        end

      is_binary(Map.get(attrs, "link")) and String.trim(Map.get(attrs, "link")) != "" ->
        link = Map.get(attrs, "link")

        feed_attrs =
          %{}
          |> maybe_put_string("title", Map.get(attrs, "title"))
          |> maybe_put_string("feed_type", Map.get(attrs, "feed_type"))

        Feeds.ensure_feed(link, feed_attrs)

      true ->
        {:error, :missing_feed}
    end
  end

  defp insert_subscription(%User{id: user_id}, %Feed{id: feed_id}, attrs) do
    sub_attrs = %{
      "user_id" => user_id,
      "feed_id" => feed_id,
      "category_id" => Map.get(attrs, "category_id"),
      "custom_title" => Map.get(attrs, "custom_title"),
      "custom_refresh_interval" => Map.get(attrs, "custom_refresh_interval"),
      "is_hidden" => Map.get(attrs, "is_hidden", false)
    }

    %Subscription{}
    |> Subscription.changeset(sub_attrs)
    |> Repo.insert()
  end

  defp clear_unsubscribed_and_queue(%Feed{} = feed) do
    now = utc_now()

    feed
    |> Feed.changeset(%{last_unsubscribed_at: nil, next_fetch_at: now})
    |> Repo.update()
  end

  defp delete_entry_states_for_user_feed(user_id, feed_id) do
    entry_ids =
      Entry
      |> where([e], e.feed_id == ^feed_id)
      |> select([e], e.id)
      |> Repo.all()

    if entry_ids != [] do
      EntryState
      |> where([st], st.user_id == ^user_id and st.entry_id in ^entry_ids)
      |> Repo.delete_all()
    end

    :ok
  end

  defp maybe_mark_feed_unsubscribed(feed_id) do
    remaining =
      Subscription
      |> where([s], s.feed_id == ^feed_id)
      |> Repo.aggregate(:count)

    if remaining == 0 do
      case Feeds.get_feed(feed_id) do
        nil ->
          :ok

        feed ->
          feed
          |> Feed.changeset(%{last_unsubscribed_at: utc_now()})
          |> Repo.update()
      end
    else
      :ok
    end
  end

  ## Internal — states

  defp upsert_state(user_id, entry_id, changes) do
    case Feeds.get_entry(entry_id) do
      nil ->
        {:error, :not_found}

      _entry ->
        existing = Repo.get_by(EntryState, user_id: user_id, entry_id: entry_id)

        base =
          case existing do
            nil -> %EntryState{user_id: user_id, entry_id: entry_id}
            state -> state
          end

        # Preserve is_star / is_read when only one field is being updated.
        attrs =
          %{
            user_id: user_id,
            entry_id: entry_id,
            is_read: if(existing, do: existing.is_read, else: false),
            is_star: if(existing, do: existing.is_star, else: false),
            read_at: if(existing, do: existing.read_at, else: nil)
          }
          |> Map.merge(changes)

        base
        |> EntryState.changeset(attrs)
        |> Repo.insert_or_update()
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, _key, ""), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
