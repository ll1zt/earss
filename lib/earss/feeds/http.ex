defmodule Earss.Feeds.HTTP do
  @moduledoc """
  HTTP client for fetching feed documents.

  Uses Req. Supports conditional requests via `ETag` / `If-Modified-Since`.
  The implementation module can be swapped in tests via
  `Application.put_env(:earss, :http_client, MockModule)`.
  """

  @type fetch_result ::
          {:ok,
           %{status: 200, body: binary(), etag: String.t() | nil, last_modified: String.t() | nil}}
          | {:ok, :not_modified}
          | {:error, {:http, term()}}

  @callback get(String.t(), keyword()) :: fetch_result()

  @doc """
  GET `url` with optional `:etag` and `:last_modified` for conditional fetch.
  """
  @spec get(String.t(), keyword()) :: fetch_result()
  def get(url, opts \\ []) when is_binary(url) do
    client().get(url, opts)
  end

  defp client do
    Application.get_env(:earss, :http_client, Earss.Feeds.HTTP.ReqClient)
  end
end

defmodule Earss.Feeds.HTTP.ReqClient do
  @moduledoc false
  @behaviour Earss.Feeds.HTTP

  @impl true
  def get(url, opts) do
    headers =
      []
      |> maybe_header("if-none-match", Keyword.get(opts, :etag))
      |> maybe_header("if-modified-since", Keyword.get(opts, :last_modified))

    request_opts = [
      headers: headers,
      decode_body: false,
      redirect: true,
      receive_timeout: Keyword.get(opts, :receive_timeout, 15_000),
      user_agent: Keyword.get(opts, :user_agent, "Earss/0.1 (+https://github.com/ll1zt/earss)")
    ]

    case Req.get(url, request_opts) do
      {:ok, %Req.Response{status: 304}} ->
        {:ok, :not_modified}

      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}}
      when status in 200..299 ->
        {:ok,
         %{
           status: status,
           body: body_to_binary(body),
           etag: header_value(resp_headers, "etag"),
           last_modified: header_value(resp_headers, "last-modified")
         }}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, {:http, exception}}
    end
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, _name, ""), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) || Map.get(headers, String.to_atom(name)) do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp header_value(headers, name) when is_list(headers) do
    case List.keyfind(headers, name, 0) || List.keyfind(headers, String.to_atom(name), 0) do
      {_, [value | _]} when is_binary(value) -> value
      {_, value} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp header_value(_, _), do: nil

  defp body_to_binary(body) when is_binary(body), do: body
  defp body_to_binary(body), do: IO.iodata_to_binary(body)
end
