defmodule Earss.Reader do
  @moduledoc """
  The Reader context facade.

  Users, categories, subscriptions, reading state, and per-user timelines.
  Lifecycle side effects follow `docs/data_lifecycle.md`.

  Implementation is split across `Earss.Reader.Users`, `Categories`, and
  related modules; this module keeps a stable public API via `defdelegate`.
  """

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.Feed
  alias Earss.Feeds.Entry
  alias Earss.Reader.User
  alias Earss.Reader.Subscription
  alias Earss.Reader.EntryState
  alias Earss.Reader.OPML
  alias Earss.Reader.Users
  alias Earss.Reader.Categories
  alias Earss.Reader.EntryStates
  alias Earss.Fever.Queries, as: FeverQueries

  ## Users

  defdelegate create_sub_user(username, password), to: Users
  def create_user(username, password, user_type \\ "admin"),
    do: Users.create_user(username, password, user_type)

  defdelegate get_user(id), to: Users
  defdelegate get_user_by_username(username), to: Users
  defdelegate get_user_by_fever_api_key(api_key), to: Users
  defdelegate authenticate_user(username, password), to: Users
  defdelegate set_password(user, password), to: Users
  defdelegate set_fever_password(user, secret), to: Users
  defdelegate fever_api_key(username, secret), to: Users
  defdelegate deactivate_user(user), to: Users
  defdelegate delete_user(username, password), to: Users
  defdelegate delete_user(admin_username, admin_password, sub_user_username), to: Users

  ## Categories

  defdelegate list_categories(user), to: Categories
  defdelegate get_category(id), to: Categories
  defdelegate create_category(user, attrs), to: Categories
  defdelegate update_category(category, attrs), to: Categories
  defdelegate delete_category(category), to: Categories

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

  defdelegate mark_read(user, entry_id), to: EntryStates
  defdelegate mark_unread(user, entry_id), to: EntryStates
  defdelegate set_star(user, entry_id, starred?), to: EntryStates
  defdelegate get_entry_state(user, entry_id), to: EntryStates
  defdelegate mark_entries_read(user, opts), to: EntryStates

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

  defp ensure_category(user, name), do: Categories.ensure_category(user, name)

  ## Fever helpers (Earss.Fever.Queries — D2)

  def list_unread_entry_ids(user, opts \\ []), do: FeverQueries.list_unread_entry_ids(user, opts)
  def list_starred_entry_ids(user, opts \\ []), do: FeverQueries.list_starred_entry_ids(user, opts)
  defdelegate count_fever_items(user), to: FeverQueries
  def list_fever_items(user, opts \\ []), do: FeverQueries.list_fever_items(user, opts)

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
