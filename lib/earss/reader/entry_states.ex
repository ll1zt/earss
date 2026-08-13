defmodule Earss.Reader.EntryStates do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.Entry
  alias Earss.Reader
  alias Earss.Reader.EntryState
  alias Earss.Reader.Subscription

  def mark_read(entry_id), do: upsert_state(entry_id, %{is_read: true})

  def mark_unread(entry_id), do: upsert_state(entry_id, %{is_read: false, read_at: nil})

  def set_star(entry_id, starred?) when is_boolean(starred?) do
    upsert_state(entry_id, %{is_star: starred?})
  end

  def get_entry_state(entry_id) do
    Repo.get_by(EntryState, entry_id: entry_id)
  end

  @doc """
  Mark many entries read.

  Options:
    * `:ids` — list of entry ids
    * `:feed_id` — all entries of a subscribed feed
  """
  def mark_entries_read(opts) when is_list(opts) or is_map(opts) do
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

          case Reader.get_subscription(feed_id) do
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
          entry_ids_for_operator(before_ts)

        category_id ->
          category_id = normalize_id(category_id)

          feed_ids =
            Subscription
            |> where([s], s.category_id == ^category_id)
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
            case mark_read(id) do
              {:ok, _} -> acc + 1
              {:error, _} -> acc
            end
          end)

        {:ok, %{marked: marked}}
    end
  end

  defp upsert_state(entry_id, changes) do
    case Feeds.get_entry(entry_id) do
      nil ->
        {:error, :not_found}

      _entry ->
        existing = Repo.get_by(EntryState, entry_id: entry_id)

        base =
          case existing do
            nil -> %EntryState{entry_id: entry_id}
            state -> state
          end

        # Preserve is_star / is_read when only one field is being updated.
        attrs =
          %{
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

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp normalize_id(_), do: nil

  defp entry_ids_for_operator(before_ts) do
    from(e in Entry,
      join: s in Subscription,
      on: s.feed_id == e.feed_id,
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
end
