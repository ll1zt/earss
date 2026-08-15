defmodule Earss.Feeds.HTTP do
  @moduledoc """
  HTTP client for fetching feed documents.

  Uses Req. Supports conditional requests via `ETag` / `If-Modified-Since`.
  Outbound calls go through `Earss.Feeds.HostLimiter` (per-host politeness).

  The implementation module can be swapped in tests via
  `Application.put_env(:earss, :http_client, MockModule)`.
  """

  alias Earss.Feeds.HostLimiter

  @type fetch_result ::
          {:ok,
           %{status: 200, body: binary(), etag: String.t() | nil, last_modified: String.t() | nil}}
          | {:ok, :not_modified}
          | {:error, {:http, term()}}

  @callback get(String.t(), keyword()) :: fetch_result()

  @doc """
  GET `url` with optional `:etag` and `:last_modified` for conditional fetch.

  Acquires a per-host politeness slot before delegating to the configured client.
  """
  @spec get(String.t(), keyword()) :: fetch_result()
  def get(url, opts \\ []) when is_binary(url) do
    host = HostLimiter.host_key_for(url)

    case HostLimiter.checkout(host) do
      :ok ->
        try do
          client().get(url, opts)
        after
          HostLimiter.checkin(host)
        end

      {:error, :timeout} ->
        {:error, {:http, {:host_limiter, :timeout, host}}}
    end
  end

  defp client do
    Application.get_env(:earss, :http_client, Earss.Feeds.HTTP.ReqClient)
  end

  @doc """
  Whether a redirect target is safe to fetch.

  Allows `http(s)` URLs only. Literal IP hosts inside blocked ranges —
  loopback, private (RFC 1918), link-local (incl. cloud metadata
  169.254.169.254), CGNAT 100.64/10 (**the tailnet range**), multicast,
  reserved, and their IPv6 equivalents (::1, ::, fc00::/7, fe80::/10,
  ff00::/8, IPv4-mapped) — are rejected. Hostnames pass here; they resolve
  at connect time, so DNS rebinding remains a documented residual risk
  (mitigate by not subscribing to untrusted hosts).
  """
  @spec safe_redirect_target?(String.t() | URI.t()) :: boolean()
  def safe_redirect_target?(%URI{} = uri) do
    case uri do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != "" and not blocked_ip?(host)

      _ ->
        false
    end
  end

  def safe_redirect_target?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{} = uri -> safe_redirect_target?(uri)
      _ -> false
    end
  end

  def safe_redirect_target?(_), do: false

  defp blocked_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> blocked_address?(ip)
      {:error, _} -> false
    end
  end

  import Bitwise

  # IPv4
  defp blocked_address?({a, _, _, _}) when a in [0, 10, 127], do: true
  defp blocked_address?({100, b, _, _}) when b in 64..127, do: true
  defp blocked_address?({169, 254, _, _}), do: true
  defp blocked_address?({172, b, _, _}) when b in 16..31, do: true
  defp blocked_address?({192, 168, _, _}), do: true
  defp blocked_address?({192, 0, 0, _}), do: true
  defp blocked_address?({192, 0, 2, _}), do: true
  defp blocked_address?({198, 18, _, _}), do: true
  defp blocked_address?({198, 51, 100, _}), do: true
  defp blocked_address?({203, 0, 113, _}), do: true
  defp blocked_address?({a, _, _, _}) when a >= 224, do: true

  # IPv6
  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp blocked_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv4-mapped (::ffff:a.b.c.d) — unwrap and apply the IPv4 rules
  defp blocked_address?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: blocked_address?({a >>> 8, a &&& 0xFF, b >>> 8, b &&& 0xFF})

  defp blocked_address?({h1, _, _, _, _, _, _, _})
       when h1 >= 0xFC00 and h1 < 0xFE00,
       do: true

  defp blocked_address?({h1, _, _, _, _, _, _, _})
       when h1 >= 0xFE80 and h1 <= 0xFEBF,
       do: true

  defp blocked_address?({h1, _, _, _, _, _, _, _}) when h1 >= 0xFF00, do: true

  defp blocked_address?(_), do: false
end

defmodule Earss.Feeds.HTTP.ReqClient do
  @moduledoc false
  @behaviour Earss.Feeds.HTTP

  alias Earss.Feeds.HostLimiter
  alias Earss.Source.Politeness

  @max_redirects 5
  @default_max_body_bytes 25 * 1024 * 1024

  @impl true
  def get(url, opts) do
    http = Application.get_env(:earss, :http, [])
    do_get(url, opts, http, 0)
  end

  # Manual redirect loop (Req's redirect: true follows anything, including
  # redirects into private/tailnet address space — SSRF). Every hop is
  # validated by Earss.Feeds.HTTP.safe_redirect_target?/1 and the body is
  # streamed with a size cap so a malicious feed cannot balloon memory.
  defp do_get(_url, _opts, _http, redirects) when redirects > @max_redirects do
    {:error, {:http, :too_many_redirects}}
  end

  defp do_get(url, opts, http, redirects) do
    host = HostLimiter.host_key_for(url)

    headers =
      []
      |> maybe_header("if-none-match", Keyword.get(opts, :etag))
      |> maybe_header("if-modified-since", Keyword.get(opts, :last_modified))

    max_body =
      Keyword.get(http, :max_body_bytes, @default_max_body_bytes)

    request_opts = [
      headers: headers,
      decode_body: false,
      redirect: false,
      into: body_cap_collector(max_body),
      receive_timeout:
        Keyword.get(opts, :receive_timeout, Keyword.get(http, :receive_timeout, 15_000)),
      user_agent:
        Keyword.get(
          opts,
          :user_agent,
          Keyword.get(http, :user_agent, "Earss/0.1 (+https://github.com/ll1zt/earss)")
        )
    ]

    try do
      do_request(url, request_opts, http, redirects, host)
    catch
      {:earss_body_cap, _size} -> {:error, {:http, :body_too_large}}
    end
  end

  defp do_request(url, request_opts, http, redirects, host) do
    case Req.get(url, request_opts) do
      {:ok, %Req.Response{status: status, headers: resp_headers}}
      when status in [301, 302, 303, 307, 308] ->
        case header_value(resp_headers, "location") do
          nil ->
            {:error, {:http, status}}

          location ->
            target = URI.merge(URI.parse(url), location)

            if Earss.Feeds.HTTP.safe_redirect_target?(target) do
              do_get(URI.to_string(target), [], http, redirects + 1)
            else
              {:error, {:http, {:blocked_redirect, target.host || target.authority}}}
            end
        end

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

      {:ok, %Req.Response{status: status, headers: resp_headers}}
      when status in [429, 503] ->
        ra = Politeness.retry_after_seconds(resp_headers)
        HostLimiter.penalize(host, ra)
        {:error, {:http, status}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, {:http, exception}}
    end
  end

  # Stream-accumulate the body with a hard size cap. With into: fun, Req
  # hands chunks over without materializing the body; we accumulate and
  # throw once the cap is exceeded (caught in do_get/4).
  defp body_cap_collector(max_body) do
    fn {:data, data}, {req, resp} ->
      acc = resp.body || []

      total =
        byte_size(data) +
          if(is_binary(acc), do: byte_size(acc), else: :erlang.iolist_size(acc))

      if total > max_body do
        throw({:earss_body_cap, total})
      end

      {:cont, {req, %{resp | body: [acc, data]}}}
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
