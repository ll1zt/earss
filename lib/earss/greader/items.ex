defmodule Earss.GReader.Items do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Reader
  alias Earss.Reader.Subscription
  alias Earss.Feeds.Entry
  alias Earss.Feeds.Feed
  alias Earss.Reader.EntryState
  alias Earss.Reader.Category
  alias Earss.GReader.Ids
  alias Earss.GReader.Streams
  alias Earss.GReader.Format
  alias Earss.API.Translation

  def items_contents(item_ids, opts \\ []) when is_list(item_ids) do
    ids =
      item_ids
      |> Enum.map(&Ids.parse_item_id/1)
      |> Enum.reject(&is_nil/1)

    rows =
      if ids == [] do
        []
      else
        from(e in Entry,
          join: s in Subscription,
          on: s.feed_id == e.feed_id,
          join: f in Feed,
          on: f.id == e.feed_id,
          left_join: st in EntryState,
          on: st.entry_id == e.id,
          left_join: c in Category,
          on: c.id == s.category_id,
          where: e.id in ^ids,
          # contents for ids the client already knows must match what the
          # streams advertised — pending entries are hidden there, so they
          # are hidden here too (a re-flagged entry must not be fetchable)
          where: is_nil(e.translation_pending_at),
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
    rows = Translation.attach(rows, original: Keyword.get(opts, :original, false))

    %{
      "direction" => "ltr",
      "id" => "user/-/state/com.google/reading-list",
      "title" => "Reading list",
      "description" => "",
      "updated" => System.system_time(:second),
      "items" => Enum.map(rows, &Format.entry_item(&1, opts))
    }
  end

  ## edit-tag

  def edit_tag(item_ids, add, remove) do
    ids =
      item_ids
      |> List.wrap()
      |> Enum.map(&Ids.parse_item_id/1)
      |> Enum.reject(&is_nil/1)

    add = List.wrap(add)
    remove = List.wrap(remove)

    Enum.each(ids, fn id ->
      cond do
        Enum.any?(add, &read_state?/1) -> Reader.mark_read(id)
        Enum.any?(remove, &read_state?/1) -> Reader.mark_unread(id)
        true -> :ok
      end

      cond do
        Enum.any?(add, &star_state?/1) -> Reader.set_star(id, true)
        Enum.any?(remove, &star_state?/1) -> Reader.set_star(id, false)
        true -> :ok
      end
    end)

    :ok
  end

  defp read_state?(s), do: String.contains?(to_string(s), "state/com.google/read")
  defp star_state?(s), do: String.contains?(to_string(s), "state/com.google/starred")

  ## mark-all-as-read

  def mark_all_as_read(stream_id, _timestamp_sec \\ nil) do
    stream_id = Ids.normalize_stream_id(stream_id)

    cond do
      Ids.reading_list_stream?(stream_id) ->
        Reader.mark_entries_read(category_id: 0)

      String.starts_with?(to_string(stream_id), "feed/") ->
        case Streams.feed_from_stream(stream_id) do
          %Feed{id: id} -> Reader.mark_entries_read(feed_id: id)
          _ -> {:ok, %{marked: 0}}
        end

      String.contains?(to_string(stream_id), "/label/") ->
        label = Ids.label_from_stream(stream_id)

        case Repo.get_by(Category, name: label) do
          %Category{id: id} -> Reader.mark_entries_read(category_id: id)
          _ -> {:ok, %{marked: 0}}
        end

      true ->
        {:ok, %{marked: 0}}
    end
  end
end
