defmodule Earss.Source.Resolver do
  @moduledoc """
  Resolve which `Earss.Source.Adapter` handles a feed link or feed row.
  """

  alias Earss.Source.Registry

  @native_id "native"

  @doc "Adapter id for a feed struct/map (`adapter_id` field or parsed from `link`)."
  @spec adapter_id(struct() | map() | String.t()) :: String.t()
  def adapter_id(%{adapter_id: id}) when is_binary(id) and id != "", do: id
  def adapter_id(%{"adapter_id" => id}) when is_binary(id) and id != "", do: id

  def adapter_id(%{link: link}) when is_binary(link), do: adapter_id_from_link(link)
  def adapter_id(%{"link" => link}) when is_binary(link), do: adapter_id_from_link(link)
  def adapter_id(link) when is_binary(link), do: adapter_id_from_link(link)
  def adapter_id(_), do: @native_id

  @doc "Adapter module for a feed or link. Falls back to native."
  @spec adapter_module(struct() | map() | String.t()) :: module()
  def adapter_module(feed_or_link) do
    id = adapter_id(feed_or_link)

    case Registry.fetch(id) do
      {:ok, mod} -> mod
      :error -> native_module()
    end
  end

  @doc """
  Resolve a subscription link to canonical source attributes.

  Returns `{:ok, map}` with at least `:source_url`, `:adapter_id`, `:source_kind`.
  """
  @spec resolve_link(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_link(link) when is_binary(link) do
    link = String.trim(link)
    id = adapter_id_from_link(link)

    with {:ok, mod} <- fetch_adapter(id),
         {:ok, resolved} <- mod.resolve(link) do
      source_url = Map.fetch!(resolved, :source_url) |> to_string() |> String.trim()

      kind = if id == @native_id, do: "native", else: "plugin"
      feed_type = if kind == "plugin", do: "plugin", else: Map.get(resolved, :feed_type)

      attrs =
        %{
          source_url: source_url,
          adapter_id: id,
          source_kind: kind,
          title: Map.get(resolved, :title),
          meta: Map.get(resolved, :meta) || %{},
          min_refresh_interval: Map.get(resolved, :min_refresh_interval),
          max_refresh_interval: Map.get(resolved, :max_refresh_interval),
          default_refresh_interval: Map.get(resolved, :default_refresh_interval)
        }
        |> then(fn m -> if feed_type, do: Map.put(m, :feed_type, feed_type), else: m end)

      {:ok, attrs}
    end
  end

  def resolve_link(_), do: {:error, :invalid_link}

  @doc false
  def native_id, do: @native_id

  defp fetch_adapter(id) do
    case Registry.fetch(id) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_adapter, id}}
    end
  end

  defp native_module do
    case Registry.fetch(@native_id) do
      {:ok, mod} -> mod
      :error -> Earss.Source.Native
    end
  end

  defp adapter_id_from_link(link) do
    uri = URI.parse(link)

    case uri.scheme do
      "earss" ->
        cond do
          is_binary(uri.host) and uri.host != "" ->
            uri.host

          is_binary(uri.path) ->
            first_segment =
              uri.path
              |> String.trim_leading("/")
              |> String.split("/", parts: 2)
              |> List.first()

            case first_segment do
              id when is_binary(id) and id != "" -> id
              _ -> @native_id
            end

          true ->
            @native_id
        end

      scheme when scheme in ["http", "https", nil] ->
        @native_id

      _ ->
        # Unknown schemes are not native feed URLs; force lookup (will error on resolve)
        if is_binary(uri.host) and uri.host != "", do: uri.host, else: @native_id
    end
  end
end
