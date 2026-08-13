defmodule Earss.Reader.Timeline do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Feeds.Entry
  alias Earss.Reader.EntryState
  alias Earss.Reader.Subscription

  @doc """
  List entries visible to the operator via subscriptions.

  Options:
    * `:limit` / `:offset`
    * `:feed_id` — single feed
    * `:category_id` — subscriptions in category (`:none` for uncategorized)
    * `:unread_only` — true filters to unread (no state or is_read=false)
    * `:starred_only` — true filters to starred
    * `:include_hidden` — include hidden subscriptions (default false)
  """
  def list_entries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    include_hidden? = Keyword.get(opts, :include_hidden, false)

    query =
      from(e in Entry,
        join: s in Subscription,
        on: s.feed_id == e.feed_id,
        left_join: st in EntryState,
        on: st.entry_id == e.id,
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

    # Goal 2: hide entries still inside the translation window (they have no
    # translation yet; showing the original would let clients cache it forever).
    query =
      from([e, s, st] in query,
        join: f in Earss.Feeds.Feed,
        on: f.id == e.feed_id,
        where: is_nil(e.translation_pending_at)
      )

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
end
