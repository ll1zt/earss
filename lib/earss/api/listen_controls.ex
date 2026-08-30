defmodule Earss.API.ListenControls do
  @moduledoc """
  Injects a "listen to this article" control into entry content at
  protocol-render time (GReader items, Fever items, JSON API rows).

  The anchor opens `Earss.TTS.Link.url/1` in the reader's browser; the
  endpoint records the intent. The fragment is built from static parts plus
  the signed URL only — nothing read from the article goes into it — and it
  is appended once per rendered response, never stored: the shared
  `entries.content` stays untouched.

  Note the NetNewsWire caching consequence: content is snapshotted on fetch,
  so the control appears only in articles fetched *after* this feature was
  enabled, and its label never changes for an already-fetched article (the
  server-side confirm page owns all state feedback).

  Disabled unless `config :earss, :tts` sets `listen_controls: true` and a
  base URL is resolvable: the configured `public_url` if set, else the
  reader request's own scheme/host (see `request_base/1`) — so out of the
  box the control points at the same address the client already talks to.
  """

  alias Earss.TTS.Link

  # Kept filter-friendly for NNW's HTML sanitisation: plain <a> inside <p>,
  # inline attributes only, no scripts or styles.
  @prefix ~s(<hr class="earss-listen"><p>)
  @anchor_tail ~s(" target="_blank" rel="noopener" class="earss-listen-link">🎧 Listen</a></p>)

  @doc """
  Prepend the listen control to `content`, or pass through when disabled.

  The control leads the article so it is visible without scrolling; it is
  rendered *before* the content but conceptually belongs to the reader
  chrome, not the article body. Always returns a string while enabled
  (`nil` content becomes just the control — title-only articles are still
  listenable). Disabled, `content` is returned unchanged.
  """
  @spec decorate(String.t() | nil, pos_integer()) :: String.t() | nil
  def decorate(content, entry_id) do
    decorate(content, entry_id, nil)
  end

  @doc "Like `decorate/2`, with a request-derived base (see `request_base/1`)."
  @spec decorate(String.t() | nil, pos_integer(), String.t() | nil) :: String.t() | nil
  def decorate(content, entry_id, base) when is_integer(entry_id) and entry_id > 0 do
    case Link.url(entry_id, base) do
      nil ->
        content

      url ->
        IO.iodata_to_binary([@prefix, ~s(<a href="), url, @anchor_tail, content || ""])
    end
  end

  def decorate(content, _entry_id, _base), do: content

  @doc """
  Base URL for listen links on this request.

  The configured `public_url` wins — a deployment may be reachable from the
  reader under a different address than the one a browser should use (reverse
  proxy, tunnel). Otherwise the reader request's own scheme/host is used:
  the control then points at exactly the address the client already talks to,
  so a plain `listen_controls: true` is enough.

  The value only lands in signed links rendered back to the requester, so
  `Host`-header spoofing here cannot affect anyone else.
  """
  @spec request_base(Plug.Conn.t()) :: String.t()
  def request_base(%Plug.Conn{} = conn) do
    Link.configured_public_url() || conn_base(conn)
  end

  defp conn_base(conn) do
    host =
      case {conn.scheme, conn.port} do
        {:http, 80} -> conn.host
        {:https, 443} -> conn.host
        {_, port} -> "#{conn.host}:#{port}"
      end

    "#{conn.scheme}://#{host}"
  end
end
