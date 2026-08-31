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

  # A single INSERT ... ON CONFLICT rather than read-then-write.
  #
  # The previous version read the row with Repo.get_by/2 and then inserted or
  # updated. Two concurrent calls for the same entry both saw nil and both
  # tried to insert, so one lost the unique-index race and surfaced as
  # "has already been taken" — an agent marking several entries in parallel
  # hit it immediately. Letting PostgreSQL resolve the conflict makes the
  # write atomic and removes the round trip.
  #
  # The conflict clause sets only the fields being changed, so updating read
  # state leaves the star alone and vice versa. On insert the same attrs plus
  # the schema defaults apply, which keeps the lazy-row invariant (decision
  # D2): a missing row still means unread and unstarred.
  defp upsert_state(entry_id, changes) do
    case Feeds.get_entry(entry_id) do
      nil ->
        {:error, :not_found}

      _entry ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        # Attributes for a fresh row: the requested change plus the defaults
        # a lazily created row needs (decision D2 — a missing row means
        # unread and unstarred).
        insert_attrs =
          %{
            entry_id: entry_id,
            is_read: false,
            is_star: false,
            read_at: nil,
            inserted_at: now,
            updated_at: now
          }
          |> Map.merge(changes)
          |> put_consistent_read_at(now)

        %EntryState{}
        |> EntryState.changeset(insert_attrs)
        |> Repo.insert(
          on_conflict: [set: conflict_set(changes, now)],
          conflict_target: :entry_id,
          returning: true
        )
    end
  end

  # What the conflict path writes: only the fields this call changes, plus
  # updated_at.
  #
  # Reusing the insert defaults here would clobber unrelated columns —
  # setting is_star on an already-read entry would reset read_at to NULL
  # while is_read stayed true, which the entry_states_read_at_consistency
  # check rejects.
  defp conflict_set(changes, now) do
    changes
    |> Map.take([:is_read, :is_star, :read_at])
    |> then(fn set ->
      if Map.has_key?(set, :is_read) do
        # The ON CONFLICT clause bypasses the changeset, so the read_at rule
        # (read implies a non-NULL read_at, unread implies NULL) is applied
        # here rather than in EntryState.changeset/2.
        case set do
          %{is_read: true} -> Map.put_new(set, :read_at, now)
          %{is_read: false} -> Map.put(set, :read_at, nil)
          other -> other
        end
      else
        set
      end
    end)
    |> Map.put(:updated_at, now)
    |> Map.to_list()
  end

  # Applied to the insert attributes only: a fresh row has no existing
  # read_at to preserve, so the rule reduces to "read implies a timestamp".
  defp put_consistent_read_at(%{is_read: true, read_at: nil} = attrs, now),
    do: %{attrs | read_at: now}

  defp put_consistent_read_at(%{is_read: false} = attrs, _now), do: %{attrs | read_at: nil}

  defp put_consistent_read_at(attrs, _now), do: attrs

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
