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

  Base resolution: the configured `public_url` wins — a deployment may be
  reachable from the reader under a different address than the one a browser
  should use (reverse proxy, tunnel, custom domain). Without it, the `base`
  derived from the reader's own request is used (see
  `Earss.API.ListenControls.request_base/1`). Injection stays
  off unless `listen_controls: true` and a base is resolvable.
  """
  @spec url(pos_integer(), String.t() | nil) :: String.t() | nil
  def url(entry_id, base \\ nil) when is_integer(entry_id) and entry_id > 0 do
    if listen_controls_enabled?() do
      case configured_public_url() || base do
        b when is_binary(b) ->
          "#{String.trim_trailing(b, "/")}/tts/listen/#{entry_id}?sig=#{sign(entry_id)}"

        nil ->
          nil
      end
    else
      nil
    end
  end

  @doc "Configured absolute base URL override, when set."
  @spec configured_public_url() :: String.t() | nil
  def configured_public_url do
    Application.get_env(:earss, :tts, [])
    |> Keyword.get(:public_url)
  end

  defp listen_controls_enabled? do
    Application.get_env(:earss, :tts, [])
    |> Keyword.get(:listen_controls, false)
  end

  defp secret do
    Application.get_env(:earss, :api, [])
    |> Keyword.get(:secret_key_base) ||
      raise "config :earss, :api, secret_key_base is not set"
  end
end
