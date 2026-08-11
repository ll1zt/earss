defmodule Earss.Export.Query do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Feeds.Entry
  alias Earss.Feeds.Feed
  alias Earss.Reader.EntryState
  alias Earss.Reader.Subscription
  alias Earss.Reader.User

  @doc """
  Starred entries of a user, newest first.

  Includes entries from hidden subscriptions: an explicit star is the
  user's intent regardless of feed visibility.
  """
  @spec starred(integer()) :: Ecto.Query.t()
  def starred(user_id) do
    from(e in Entry,
      join: f in Feed,
      on: f.id == e.feed_id,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id,
      join: st in EntryState,
      on: st.entry_id == e.id and st.user_id == ^user_id,
      where: st.is_star == true,
      order_by: [desc_nulls_last: e.published_at, desc: e.id],
      select: %{
        feed_id: f.id,
        feed_title: f.title,
        feed_link: f.link,
        site_url: f.site_url,
        feed_type: f.feed_type,
        entry_id: e.id,
        link: e.link,
        guid: e.guid,
        title: e.title,
        author: e.author,
        summary: e.summary,
        content: e.content,
        published_at: e.published_at,
        inserted_at: e.inserted_at,
        is_read: fragment("coalesce(?, false)", st.is_read),
        is_star: fragment("coalesce(?, false)", st.is_star),
        read_at: st.read_at
      }
    )
  end

  @doc """
  Every entry of a feed the user is subscribed to, newest first.
  """
  @spec feed(integer(), term()) :: Ecto.Query.t()
  def feed(user_id, feed_id) do
    from(e in Entry,
      join: f in Feed,
      on: f.id == e.feed_id,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id,
      left_join: st in EntryState,
      on: st.entry_id == e.id and st.user_id == ^user_id,
      where: e.feed_id == ^feed_id,
      order_by: [desc_nulls_last: e.published_at, desc: e.id],
      select: %{
        feed_id: f.id,
        feed_title: f.title,
        feed_link: f.link,
        site_url: f.site_url,
        feed_type: f.feed_type,
        entry_id: e.id,
        link: e.link,
        guid: e.guid,
        title: e.title,
        author: e.author,
        summary: e.summary,
        content: e.content,
        published_at: e.published_at,
        inserted_at: e.inserted_at,
        is_read: fragment("coalesce(?, false)", st.is_read),
        is_star: fragment("coalesce(?, false)", st.is_star),
        read_at: st.read_at
      }
    )
  end

  @doc """
  Every entry on the instance, newest first (admin archive).

  Reading state is per-user, so rows carry `is_read` / `is_star` / `read_at`
  as `nil`.
  """
  @spec all() :: Ecto.Query.t()
  def all do
    from(e in Entry,
      join: f in Feed,
      on: f.id == e.feed_id,
      order_by: [desc_nulls_last: e.published_at, desc: e.id],
      select: %{
        feed_id: f.id,
        feed_title: f.title,
        feed_link: f.link,
        site_url: f.site_url,
        feed_type: f.feed_type,
        entry_id: e.id,
        link: e.link,
        guid: e.guid,
        title: e.title,
        author: e.author,
        summary: e.summary,
        content: e.content,
        published_at: e.published_at,
        inserted_at: e.inserted_at,
        is_read: nil,
        is_star: nil,
        read_at: nil
      }
    )
  end

  @doc """
  The feed behind a user's subscription, or `nil` when not subscribed.
  """
  @spec find_subscribed_feed(User.t(), term()) :: Feed.t() | nil
  def find_subscribed_feed(%User{id: user_id}, feed_id) do
    from(s in Subscription,
      join: f in Feed,
      on: f.id == s.feed_id,
      where: s.user_id == ^user_id and s.feed_id == ^feed_id,
      select: f
    )
    |> Repo.one()
  end
end
