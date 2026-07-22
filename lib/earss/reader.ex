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

  ## Users

  def create_sub_user(username, password), do: create_user(username, password, "sub_user")

  def create_user(username, password, user_type \\ "admin") do
    %{
      username: username,
      password_hash: Argon2.hash_pwd_salt(password),
      user_type: user_type
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

    Repo.transaction(fn ->
      with {:ok, feed} <- resolve_feed_for_subscribe(attrs),
           {:ok, subscription} <- insert_subscription(user, feed, attrs),
           {:ok, feed} <- clear_unsubscribed_and_queue(feed) do
        if refresh? do
          # Best-effort; failures should not roll back the subscription.
          _ = Feeds.refresh(feed)
        end

        Repo.preload(subscription, [:feed, :category])
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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

  def list_subscriptions(%User{id: user_id}, opts \\ []) do
    include_hidden? = Keyword.get(opts, :include_hidden, true)

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

    Repo.all(query)
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
