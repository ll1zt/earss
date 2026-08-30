defmodule Earss.MCP.Containers do
  @moduledoc """
  Container feeds: the parent an agent's collected entries live under.

  Entries cannot float free — `entries.feed_id` is NOT NULL — so content an
  agent collected from outside any feed needs a parent. A container is that
  parent: a real feed row with `feed_type: "manual"` that is never fetched.

  Being a real feed is what makes this worth doing rather than a separate
  table: entries in a container immediately get subscriptions, read/starred
  state, OPML export, translation, TTS and retention for free, by the same
  code paths that serve ordinary feeds.

  ## Why these feeds are never fetched

  `Earss.Source.Resolver.adapter_module/1` falls back to the native adapter
  for any unknown `adapter_id`, so an invented id would be fetched as RSS —
  against a URL that is not a URL. Containers therefore use
  `adapter_id: "native"` (the registered default) and a `link` of
  `earss://agent/<name>`. Even if something did try to fetch it, the
  `earss://` scheme is rejected by the SSRF gate in `Earss.Feeds.HTTP`,
  which permits http and https only. Belt and braces: the link cannot be
  fetched, and no scheduler query will select it either, because
  `FeedScheduler.list_due_feeds/2` requires a subscription row.
  """

  import Ecto.Query, warn: false

  alias Earss.Feeds
  alias Earss.Feeds.Feed
  alias Earss.Repo

  @prefix "earss://agent/"

  @max_name_length 200

  @doc """
  Link for a container name. Exposed so tests and tools agree on the format.
  """
  @spec link(String.t()) :: String.t()
  def link(name) when is_binary(name), do: @prefix <> name

  @doc """
  Find or create the container feed named `name`.

  `opts` may carry `:title` and `:translate_to`, applied when the container
  is created. On an existing container they are ignored — a later ingest must
  not silently change what an operator already configured.

  Returns `{:error, :invalid_container}` for a name that is empty, too long,
  or contains characters that would break the link or the admin UI.
  """
  @spec ensure(String.t(), keyword()) :: {:ok, Feed.t()} | {:error, term()}
  def ensure(name, opts \\ [])

  def ensure(name, opts) when is_binary(name) do
    name = String.trim(name)

    if valid_name?(name) do
      link = link(name)

      case Feeds.get_feed_by_link(link) do
        %Feed{} = feed ->
          {:ok, feed}

        nil ->
          create_container(name, link, opts)
      end
    else
      {:error, :invalid_container}
    end
  end

  def ensure(_, _opts), do: {:error, :invalid_container}

  @doc """
  Whether `feed` is an agent container.
  """
  @spec container?(Feed.t()) :: boolean()
  def container?(%Feed{feed_type: "manual"}), do: true
  def container?(%Feed{}), do: false

  @doc """
  Container feeds, newest first, with their entry counts.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50) |> max(1) |> min(200)

    Feed
    |> where([f], f.feed_type == "manual")
    |> order_by([f], desc: f.inserted_at, desc: f.id)
    |> limit(^limit)
    |> Repo.all()
  end

  ## Internal

  defp create_container(name, link, opts) do
    attrs = %{
      "link" => link,
      "feed_type" => "manual",
      # Deliberately the registered default rather than an invented id:
      # Resolver.adapter_module/1 falls back to native for unknown ids, so an
      # invented one would resolve to the native adapter anyway — but through
      # the error path, which is the fragile way to get the same answer.
      "adapter_id" => "native",
      "source_kind" => "native",
      "title" => Keyword.get(opts, :title) || name,
      "translate_to" => Keyword.get(opts, :translate_to)
    }

    case Feeds.create_feed(attrs) do
      {:ok, feed} -> {:ok, feed}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  # The name becomes part of a stored link and is rendered in the admin UI,
  # so it must not contain whitespace (link breakage), control characters
  # (log and header injection), or markup delimiters.
  defp valid_name?(name) do
    name != "" and
      String.length(name) <= @max_name_length and
      not String.match?(name, ~r/[\s<>]/u) and
      not String.match?(name, ~r/[[:cntrl:]]/u)
  end
end
