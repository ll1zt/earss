defmodule Earss.SourceStub do
  @moduledoc false
  @behaviour Earss.Source.Adapter

  alias Earss.Source.Adapter
  alias Earss.Source.Registry

  @impl true
  def id, do: "stub"

  @impl true
  def adapter_api, do: Adapter.api_version()

  @impl true
  def routes do
    [
      %{
        path: "ping/:name",
        description: "Test stub route",
        example: "earss://stub/ping/world"
      }
    ]
  end

  @impl true
  def resolve("earss://stub/ping/" <> name) do
    name = String.trim(name)

    if name == "" do
      {:error, :invalid_route}
    else
      {:ok,
       %{
         source_url: "earss://stub/ping/#{name}",
         title: "Stub #{name}",
         meta: %{name: name}
       }}
    end
  end

  def resolve(_), do: {:error, :unknown_route}

  @impl true
  def fetch(feed, _opts) do
    name =
      feed.link
      |> URI.parse()
      |> Map.get(:path)
      |> to_string()
      |> Path.basename()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    guid = "stub-#{name}-1"

    {:ok,
     %{
       feed: %{title: "Stub #{name}", site_url: "https://example.com"},
       feed_type: "plugin",
       entries: [
         %{
           guid: guid,
           link: "https://example.com/stub/#{name}",
           title: "Hello #{name}",
           content: "<p>stub</p>",
           published_at: now
         }
       ],
       content_hash: guid,
       cursor: %{"n" => 1}
     }}
  end

  @doc "Register the stub adapter (idempotent)."
  def ensure_registered do
    case Registry.register(%{id: id(), module: __MODULE__, version: "test"}) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
      other -> other
    end
  end
end
