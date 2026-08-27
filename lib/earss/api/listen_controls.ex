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

  Disabled unless `config :earss, :tts` sets both `listen_controls: true`
  and an absolute `public_url` — relative hrefs cannot resolve in readers.
  """

  alias Earss.TTS.Link

  # Kept filter-friendly for NNW's HTML sanitisation: plain <a> inside <p>,
  # inline attributes only, no scripts or styles.
  @prefix ~s(<hr class="earss-listen"><p>)
  @anchor_tail ~s(" target="_blank" rel="noopener" class="earss-listen-link">🎧 Listen</a></p>)

  @doc """
  Append the listen control to `content`, or pass through when disabled.

  Always returns a string while enabled (`nil` content becomes just the
  control — title-only articles are still listenable). Disabled, `content`
  is returned unchanged.
  """
  @spec decorate(String.t() | nil, pos_integer()) :: String.t() | nil
  def decorate(content, entry_id)

  def decorate(content, entry_id) when is_integer(entry_id) and entry_id > 0 do
    case Link.url(entry_id) do
      nil ->
        content

      url ->
        IO.iodata_to_binary([content || "", @prefix, ~s(<a href="), url, @anchor_tail])
    end
  end

  def decorate(content, _entry_id), do: content
end
