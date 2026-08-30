defmodule Earss.MCP.Auth do
  @moduledoc """
  Credential checks for the agent-facing MCP endpoint (`POST /mcp`).

  Deliberately **not** `Earss.OperatorAuth`: an MCP client is a long-lived
  agent configured outside this host, so its credential has to be rotatable
  and revocable on its own. Sharing `ADMIN_PASSWORD` would mean that rotating
  the MCP key also kicks the admin UI and the JSON API out, and that revoking
  an agent's access forces a password change everywhere.

  Configuration (`config :earss, :mcp`):

    * `:enabled` — when false the endpoint is not mounted at all (default)
    * `:api_key` — the expected bearer credential; when unset every request
      is rejected
    * `:read_only` — restricts the agent to read-only tools

  Every comparison is constant-time (`Plug.Crypto.secure_compare`), matching
  `Earss.OperatorAuth`.
  """

  @doc """
  The configured MCP credential, or `nil` when unset.
  """
  @spec api_key() :: String.t() | nil
  def api_key do
    :earss
    |> Application.get_env(:mcp, [])
    |> Keyword.get(:api_key)
    |> case do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  @doc """
  Constant-time check of a presented bearer credential.

  Returns `:ok` or `{:error, reason}` so the caller can distinguish a missing
  configuration (a deployment mistake worth its own message) from a wrong
  credential (a rejected caller).
  """
  @spec verify(String.t() | nil) :: :ok | {:error, :missing_credential | :unauthorized}
  def verify(presented) when is_binary(presented) do
    case api_key() do
      nil ->
        {:error, :missing_credential}

      configured ->
        if Plug.Crypto.secure_compare(configured, presented),
          do: :ok,
          else: {:error, :unauthorized}
    end
  end

  def verify(_), do: {:error, :unauthorized}

  @doc """
  Extract the bearer credential from a `Plug.Conn`.

  Accepts `Authorization: Bearer <key>`. Anything else yields `nil` — the
  caller decides what a missing credential means.
  """
  @spec bearer_token(Plug.Conn.t()) :: String.t() | nil
  def bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [value | _] -> parse_bearer(value)
      _ -> nil
    end
  end

  defp parse_bearer("Bearer " <> rest), do: String.trim(rest)
  defp parse_bearer("bearer " <> rest), do: String.trim(rest)
  defp parse_bearer(_), do: nil

  @doc """
  Whether the endpoint is enabled at all.

  Checked before mounting so a disabled server is indistinguishable from a
  route that does not exist.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :earss
    |> Application.get_env(:mcp, [])
    |> Keyword.get(:enabled, false) == true
  end

  @doc """
  Whether the agent is restricted to read-only tools.
  """
  @spec read_only?() :: boolean()
  def read_only? do
    :earss
    |> Application.get_env(:mcp, [])
    |> Keyword.get(:read_only, false) == true
  end
end
