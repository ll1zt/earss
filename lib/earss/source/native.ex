defmodule Earss.Source.Native do
  @moduledoc """
  Built-in adapter: HTTP GET of a feed document + `Earss.Feeds.Parser`.
  """

  @behaviour Earss.Source.Adapter

  alias Earss.Feeds.HTTP
  alias Earss.Feeds.Parser
  alias Earss.Source.Adapter

  @impl true
  def id, do: "native"

  @impl true
  def adapter_api, do: Adapter.api_version()

  @impl true
  def routes, do: []

  @impl true
  def resolve(input) when is_binary(input) do
    link = String.trim(input)

    case URI.parse(link) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        {:ok, %{source_url: link}}

      %URI{scheme: nil} ->
        # bare URLs without scheme: reject (callers should pass absolute http(s))
        {:error, :unsupported_scheme}

      _ ->
        {:error, :unsupported_scheme}
    end
  end

  def resolve(_), do: {:error, :invalid_input}

  @impl true
  def fetch(feed, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    link = feed_link(feed)

    http_opts =
      if force? do
        []
      else
        [
          etag: field(feed, :etag),
          last_modified: field(feed, :last_modified)
        ]
      end

    case HTTP.get(link, http_opts) do
      {:ok, :not_modified} ->
        {:ok, :not_modified}

      {:ok, %{body: body, etag: etag, last_modified: last_modified}} ->
        hash = content_hash(body)
        prev = field(feed, :last_fetched_content_hash)

        if not force? and hash != nil and hash == prev do
          {:ok, :not_modified}
        else
          case Parser.parse(body) do
            {:ok, %{feed: feed_meta, entries: entries, feed_type: feed_type}} ->
              {:ok,
               %{
                 feed: feed_meta,
                 entries: entries,
                 feed_type: feed_type,
                 etag: etag,
                 last_modified: last_modified,
                 content_hash: hash
               }}

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp feed_link(%{link: link}) when is_binary(link), do: link
  defp feed_link(%{"link" => link}) when is_binary(link), do: link
  defp feed_link(other), do: raise(ArgumentError, "feed missing link: #{inspect(other)}")

  defp field(map, key) when is_map(map) or is_struct(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp content_hash(body) when is_binary(body) do
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end
end
