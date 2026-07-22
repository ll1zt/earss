defmodule Earss.Feeds do
  @moduledoc """
  The Feeds context.

  Owns global feed metadata and shared entry content (create / upsert).
  HTTP fetch and parsing are implemented in a later phase.
  """

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Feeds.Feed
  alias Earss.Feeds.Entry

  ## Feeds

  @doc """
  Gets a feed by primary key. Returns `nil` if missing.
  """
  @spec get_feed(term()) :: Feed.t() | nil
  def get_feed(id), do: Repo.get(Feed, id)

  @doc """
  Gets a feed by its unique `link` (after trim). Returns `nil` if missing.
  """
  @spec get_feed_by_link(String.t()) :: Feed.t() | nil
  def get_feed_by_link(link) when is_binary(link) do
    Repo.get_by(Feed, link: trim(link))
  end

  def get_feed_by_link(_), do: nil

  @doc """
  Creates a feed.

  Applies `:earss, :refresh` defaults when interval fields are omitted.
  Trims `link`. Does not set `next_fetch_at` (scheduler phase).
  """
  @spec create_feed(map()) :: {:ok, Feed.t()} | {:error, Ecto.Changeset.t()}
  def create_feed(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> put_refresh_defaults()
      |> normalize_feed_link()

    %Feed{}
    |> Feed.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an existing feed for `link` or creates one with `attrs`.

  `attrs` may override title, feed_type, etc. On existing feed, returns it
  unchanged (attrs are only used on insert).
  """
  @spec ensure_feed(String.t(), map()) :: {:ok, Feed.t()} | {:error, Ecto.Changeset.t()}
  def ensure_feed(link, attrs \\ %{}) when is_binary(link) do
    link = trim(link)

    case get_feed_by_link(link) do
      %Feed{} = feed ->
        {:ok, feed}

      nil ->
        attrs
        |> stringify_keys()
        |> Map.put("link", link)
        |> create_feed()
    end
  end

  @doc """
  Updates a feed with the given attributes.
  """
  @spec update_feed(Feed.t(), map()) :: {:ok, Feed.t()} | {:error, Ecto.Changeset.t()}
  def update_feed(%Feed{} = feed, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> normalize_feed_link()

    feed
    |> Feed.changeset(attrs)
    |> Repo.update()
  end

  ## Entries

  @doc """
  Gets an entry by primary key. Returns `nil` if missing.
  """
  @spec get_entry(term()) :: Entry.t() | nil
  def get_entry(id), do: Repo.get(Entry, id)

  @doc """
  Inserts or updates an entry for the given feed (decision D4).

  GUID normalization: trim; empty guid falls back to link; if both empty,
  returns `{:error, :invalid_entry}`.

  On conflict `(feed_id, guid)`, updates mutable content fields and
  `updated_at`. Does not touch `entry_states`.
  """
  @spec upsert_entry(Feed.t(), map()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t() | :invalid_entry}
  def upsert_entry(%Feed{id: feed_id}, attrs) when is_map(attrs) do
    case normalize_entry_attrs(feed_id, attrs) do
      :invalid_entry ->
        {:error, :invalid_entry}

      entry_attrs ->
        do_upsert_entry(entry_attrs)
    end
  end

  @doc """
  Upserts many entries for a feed.

  Invalid items (no link/guid after normalization) are skipped, not errors.

  Returns `{:ok, %{entries: [Entry.t()], skipped: non_neg_integer()}}` or
  `{:error, changeset}` if a DB-level failure occurs mid-batch (transaction
  is aborted).
  """
  @spec upsert_entries(Feed.t(), [map()]) ::
          {:ok, %{entries: [Entry.t()], skipped: non_neg_integer()}}
          | {:error, Ecto.Changeset.t()}
  def upsert_entries(%Feed{} = feed, list) when is_list(list) do
    Repo.transaction(fn ->
      Enum.reduce(list, %{entries: [], skipped: 0}, fn attrs, acc ->
        case upsert_entry(feed, attrs) do
          {:ok, entry} ->
            %{acc | entries: [entry | acc.entries]}

          {:error, :invalid_entry} ->
            %{acc | skipped: acc.skipped + 1}

          {:error, %Ecto.Changeset{} = changeset} ->
            Repo.rollback(changeset)
        end
      end)
      |> then(fn acc -> %{acc | entries: Enum.reverse(acc.entries)} end)
    end)
  end

  @doc """
  Lists entries for a feed, newest `published_at` first (nulls last), then id.

  Options:
    * `:limit` — max rows (default 100)
    * `:offset` — default 0
  """
  @spec list_entries(Feed.t(), keyword()) :: [Entry.t()]
  def list_entries(%Feed{id: feed_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    Entry
    |> where([e], e.feed_id == ^feed_id)
    |> order_by([e], desc_nulls_last: e.published_at, desc: e.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  ## Internal

  defp do_upsert_entry(entry_attrs) do
    now = utc_now()

    %Entry{}
    |> Entry.changeset(entry_attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          link: entry_attrs.link,
          title: entry_attrs[:title],
          author: entry_attrs[:author],
          summary: entry_attrs[:summary],
          content: entry_attrs[:content],
          published_at: entry_attrs[:published_at],
          content_hash: entry_attrs[:content_hash],
          updated_at: now
        ]
      ],
      conflict_target: [:feed_id, :guid],
      returning: true
    )
  end

  defp put_refresh_defaults(attrs) do
    cfg = Application.get_env(:earss, :refresh, [])

    defaults = %{
      "refresh_interval" => Keyword.get(cfg, :default_interval, 30),
      "min_refresh_interval" => Keyword.get(cfg, :min_interval, 15),
      "max_refresh_interval" => Keyword.get(cfg, :max_interval, 10_080)
    }

    Enum.reduce(defaults, attrs, fn {key, value}, acc ->
      if blank_interval?(Map.get(acc, key)) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp blank_interval?(nil), do: true
  defp blank_interval?(_), do: false

  defp normalize_feed_link(attrs) do
    case Map.fetch(attrs, "link") do
      {:ok, link} when is_binary(link) -> Map.put(attrs, "link", trim(link))
      {:ok, _} -> attrs
      :error -> attrs
    end
  end

  defp normalize_entry_attrs(feed_id, attrs) do
    attrs = stringify_keys(attrs)

    link = attrs |> Map.get("link") |> normalize_text()
    guid = attrs |> Map.get("guid") |> normalize_text()
    guid = if guid in [nil, ""], do: link, else: guid

    if link in [nil, ""] or guid in [nil, ""] do
      :invalid_entry
    else
      %{
        feed_id: feed_id,
        link: link,
        guid: guid,
        title: Map.get(attrs, "title"),
        author: Map.get(attrs, "author"),
        summary: Map.get(attrs, "summary"),
        content: Map.get(attrs, "content"),
        published_at: Map.get(attrs, "published_at"),
        content_hash: Map.get(attrs, "content_hash")
      }
    end
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    case trim(value) do
      "" -> nil
      other -> other
    end
  end

  defp normalize_text(other), do: other

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp trim(s) when is_binary(s), do: String.trim(s)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
