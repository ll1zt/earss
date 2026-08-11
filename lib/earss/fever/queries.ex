defmodule Earss.Fever.Queries do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Feeds.Entry
  alias Earss.Feeds.Feed
  alias Earss.Reader.EntryState
  alias Earss.Reader.Subscription
  alias Earss.Reader.User

  @doc """
  Unread entry ids for Fever (newest last / ascending id).
  """
  def list_unread_entry_ids(%User{id: user_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50_000)

    from(e in Entry,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id,
      join: f in Feed,
      on: f.id == e.feed_id,
      left_join: st in EntryState,
      on: st.entry_id == e.id and st.user_id == ^user_id,
      where: is_nil(st.id) or st.is_read == false,
      where: s.is_hidden == false,
      where: is_nil(e.translation_pending_at),
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
        join: f in Feed,
        on: f.id == e.feed_id,
        left_join: st in EntryState,
        on: st.entry_id == e.id and st.user_id == ^user_id,
        where: s.is_hidden == false,
        where: is_nil(e.translation_pending_at),
        select: %{
          entry: e,
          feed: f,
          sub_translate_to: s.translate_to,
          original_layout: s.original_layout,
          is_read: fragment("coalesce(?, false)", st.is_read),
          is_star: fragment("coalesce(?, false)", st.is_star)
        }
      )

    {query, reverse?} =
      cond do
        ids != [] ->
          {from([e, s, f, st] in query, where: e.id in ^ids, order_by: [asc: e.id]), false}

        is_integer(max_id) ->
          {from([e, s, f, st] in query,
             where: e.id < ^max_id,
             order_by: [desc: e.id],
             limit: ^limit
           ), true}

        is_integer(since_id) and since_id > 0 ->
          {from([e, s, f, st] in query,
             where: e.id > ^since_id,
             order_by: [asc: e.id],
             limit: ^limit
           ), false}

        true ->
          {from([e, s, f, st] in query, order_by: [asc: e.id], limit: ^limit), false}
      end

    rows = Repo.all(query)
    if reverse?, do: Enum.reverse(rows), else: rows
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp normalize_id(_), do: nil
end
