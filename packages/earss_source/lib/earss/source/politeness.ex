defmodule Earss.Source.Politeness do
  @moduledoc """
  Pure helpers for polite adapter behaviour (no I/O, no HTTP client).

  Plugins should:

    * Prefer generous `min_refresh_interval` / `default_refresh_interval` in
      `resolve/1` for remote scrapes (see `default_plugin_intervals/0`)
    * Derive a stable **host key** for any future per-host caps (`host_key/1`)
    * Honour `Retry-After` when the remote responds with 429/503
      (`retry_after_seconds/1`)

  Core enforces shared per-host crawl caps in `Earss.Feeds.HostLimiter` for the
  native HTTP client. Plugins that open their own sockets should still use
  `host_key/1` / `retry_after_seconds/1` and prefer the host limiter when the
  Earss host exposes it (or a shared HTTP helper).
  """

  @type interval_map :: %{
          min_refresh_interval: pos_integer(),
          default_refresh_interval: pos_integer(),
          max_refresh_interval: pos_integer()
        }

  @doc """
  Suggested resolve intervals (minutes) for remote site/API plugins.

  Conservative vs stock native RSS defaults (15 / 30) — scrapers and HTML
  previews should not poll every quarter hour unless the site is known-safe.
  """
  @spec default_plugin_intervals() :: interval_map()
  def default_plugin_intervals do
    %{
      min_refresh_interval: 30,
      default_refresh_interval: 60,
      max_refresh_interval: 10_080
    }
  end

  @doc """
  Clamp a refresh interval in minutes into `[min, max]`.

  Non-positive or non-integer values fall back to `default`.
  """
  @spec clamp_interval(term(), pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def clamp_interval(value, min, max, default)
      when is_integer(min) and is_integer(max) and is_integer(default) and min > 0 and max >= min and
             default > 0 do
    minutes =
      cond do
        is_integer(value) and value > 0 -> value
        true -> default
      end

    minutes |> max(min) |> min(max)
  end

  @doc """
  Lowercase host from an HTTP(S) URL, for grouping politeness / rate limits.

  Returns `nil` for missing/invalid hosts (including `earss://` plugin URLs —
  use the remote endpoint URL you actually request, not the `earss://` identity).
  """
  @spec host_key(String.t() | URI.t()) :: String.t() | nil
  def host_key(%URI{scheme: scheme, host: host})
      when scheme in ["http", "https"] and is_binary(host) and host != "" do
    String.downcase(host)
  end

  def host_key(%URI{}), do: nil

  def host_key(url) when is_binary(url) do
    url |> URI.parse() |> host_key()
  rescue
    _ -> nil
  end

  def host_key(_), do: nil

  @doc """
  Parse a `Retry-After` header value into seconds.

  Accepts integer seconds or an HTTP-date (RFC 7231). Returns `nil` if
  unparseable. `headers` may be a map (Req-style) or keyword/list of pairs.
  """
  @spec retry_after_seconds(term()) :: non_neg_integer() | nil
  def retry_after_seconds(headers) do
    case header_value(headers, "retry-after") || header_value(headers, "Retry-After") do
      nil -> nil
      value -> parse_retry_after_value(value)
    end
  end

  @doc false
  def parse_retry_after_value(value) when is_integer(value) and value >= 0, do: value

  def parse_retry_after_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {n, ""} when n >= 0 ->
        n

      _ ->
        # HTTP-date → seconds until then (best-effort; 0 if in the past)
        case parse_http_date(trimmed) do
          {:ok, dt} ->
            now = DateTime.utc_now()
            max(DateTime.diff(dt, now, :second), 0)

          :error ->
            nil
        end
    end
  end

  def parse_retry_after_value(_), do: nil

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) || Map.get(headers, String.downcase(name)) do
      [v | _] -> v
      v when is_binary(v) or is_integer(v) -> v
      _ -> nil
    end
  end

  defp header_value(headers, name) when is_list(headers) do
    down = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) or is_atom(k) ->
        if String.downcase(to_string(k)) == down, do: first_header_val(v)

      _ ->
        nil
    end)
  end

  defp header_value(_, _), do: nil

  defp first_header_val([v | _]), do: v
  defp first_header_val(v), do: v

  # Subset of IMF-fixdate / RFC 1123 used by Retry-After
  defp parse_http_date(str) do
    # Example: Tue, 15 Nov 1994 08:12:31 GMT
    case Regex.run(
           ~r/^(\w{3}), (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/,
           str
         ) do
      [_, _wd, day, mon, year, hh, mm, ss] ->
        with {:ok, month} <- month_num(mon),
             {:ok, date} <-
               Date.new(String.to_integer(year), month, String.to_integer(day)),
             {:ok, time} <-
               Time.new(String.to_integer(hh), String.to_integer(mm), String.to_integer(ss)),
             {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
          {:ok, dt}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp month_num("Jan"), do: {:ok, 1}
  defp month_num("Feb"), do: {:ok, 2}
  defp month_num("Mar"), do: {:ok, 3}
  defp month_num("Apr"), do: {:ok, 4}
  defp month_num("May"), do: {:ok, 5}
  defp month_num("Jun"), do: {:ok, 6}
  defp month_num("Jul"), do: {:ok, 7}
  defp month_num("Aug"), do: {:ok, 8}
  defp month_num("Sep"), do: {:ok, 9}
  defp month_num("Oct"), do: {:ok, 10}
  defp month_num("Nov"), do: {:ok, 11}
  defp month_num("Dec"), do: {:ok, 12}
  defp month_num(_), do: :error
end
