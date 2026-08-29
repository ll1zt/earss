defmodule Earss.TTS.Link do
  @moduledoc """
  Signed, unauthenticated "listen to this entry" links.

  The listen control is injected into article content (see
  `Earss.API.ListenControls`) and opened in the *reader's* browser —
  NetNewsWire's webview has no earss session, so the link authenticates
  itself instead: `entry_id` is signed with `SECRET_KEY_BASE` via
  `Plug.Crypto` (same scheme as `Earss.API.Token`, separate salt).

  Signatures are permanent — single-operator deployment, and a stale-but-valid
  link is exactly as meaningful as a fresh one. Forging requires the secret;
  ids cannot be enumerated without it.

  Two signed URLs for the same entry differ (Plug.Crypto embeds a random
  nonce); both verify.
  """

  @salt "earss.tts.listen"

  @doc """
  Signed token for an entry id. Inverse of `verify/1`.
  """
  @spec sign(pos_integer()) :: String.t()
  def sign(entry_id) when is_integer(entry_id) and entry_id > 0 do
    Plug.Crypto.sign(secret(), @salt, entry_id)
  end

  @doc """
  Verify a signed token, returning the entry id it was issued for.
  """
  @spec verify(String.t()) :: {:ok, pos_integer()} | :error
  def verify(token) when is_binary(token) do
    case Plug.Crypto.verify(secret(), @salt, token, max_age: :infinity) do
      {:ok, id} when is_integer(id) and id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  def verify(_), do: :error

  @doc """
  Absolute URL for the listen endpoint of an entry.

  Requires `config :earss, :tts` to set both `listen_controls: true` and an
  absolute `public_url` — relative links in feed content cannot resolve in
  reader clients, so no public URL means the control must not be injected at
  all (`Earss.API.ListenControls.enabled?/0` guards this).
  """
  @spec url(pos_integer()) :: String.t() | nil
  def url(entry_id) when is_integer(entry_id) and entry_id > 0 do
    case public_url() do
      url when is_binary(url) ->
        base = String.trim_trailing(url, "/")
        "#{base}/tts/listen/#{entry_id}?sig=#{sign(entry_id)}"

      nil ->
        nil
    end
  end

  defp public_url do
    tts_config = Application.get_env(:earss, :tts, [])
    enabled = Keyword.get(tts_config, :listen_controls, false)

    if enabled, do: Keyword.get(tts_config, :public_url)
  end

  defp secret do
    Application.get_env(:earss, :api, [])
    |> Keyword.get(:secret_key_base) ||
      raise "config :earss, :api, secret_key_base is not set"
  end
end
