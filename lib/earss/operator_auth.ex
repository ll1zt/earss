defmodule Earss.OperatorAuth do
  @moduledoc """
  Single-operator credential checks (docs/single_user.md, C2).

  All interactive surfaces share one operator password (`ADMIN_PASSWORD`
  env; fallback `config :earss, :operator_auth, :admin_password` — used by
  tests). The Fever protocol keeps its own fixed api key (`FEVER_API_KEY`
  env; fallback config) because Fever clients send an `api_key` parameter
  by protocol. Credentials live in the operator environment only — no
  users-table involvement.
  """

  @doc """
  The operator password, or `nil` when unset (auth then rejects every
  attempt and the bootstrap logs guidance).
  """
  @spec admin_password() :: String.t() | nil
  def admin_password do
    env_or_config("ADMIN_PASSWORD", :admin_password)
  end

  @doc """
  Constant-time password check.
  """
  @spec verify_admin_password(String.t()) :: boolean()
  def verify_admin_password(password) when is_binary(password) do
    case admin_password() do
      nil -> false
      configured -> Plug.Crypto.secure_compare(configured, password)
    end
  end

  def verify_admin_password(_), do: false

  @doc """
  The Fever api key, or `nil` when unset.
  """
  @spec fever_api_key() :: String.t() | nil
  def fever_api_key do
    env_or_config("FEVER_API_KEY", :fever_api_key)
  end

  @doc """
  Constant-time Fever api key check.
  """
  @spec verify_fever_api_key(String.t()) :: boolean()
  def verify_fever_api_key(key) when is_binary(key) do
    case fever_api_key() do
      nil -> false
      configured -> Plug.Crypto.secure_compare(configured, key)
    end
  end

  def verify_fever_api_key(_), do: false

  @doc """
  The operator identity map used wherever protocol/admin code needs a
  username or role (the users table disappears in the C5 migration).
  """
  @spec operator() :: %{username: String.t(), user_type: String.t()}
  def operator, do: %{username: "earss", user_type: "admin"}

  @doc """
  Warn (and never crash startup) when operator credentials are unset, or
  when an enabled surface is configured in a way that makes it unusable.

  Single-operator mode: ADMIN_PASSWORD gates the admin UI / JSON API login
  and GReader ClientLogin; FEVER_API_KEY gates the Fever protocol. Missing
  credentials mean every login attempt is rejected.
  """
  @spec validate_credentials() :: :ok
  def validate_credentials do
    require Logger

    if is_nil(admin_password()) do
      Logger.warning("""
      Earss: ADMIN_PASSWORD is not set (earss.env / environment).

      The admin UI and API login reject every attempt until a password is
      configured.
      """)
    end

    if is_nil(fever_api_key()) do
      Logger.warning("""
      Earss: FEVER_API_KEY is not set (earss.env / environment).

      NetNewsWire Fever accounts cannot authenticate until a key is
      configured.
      """)
    end

    warn_mcp_without_hosts()

    :ok
  end

  # MCP is enabled but no Host allow-list is configured. The endpoint then
  # rejects every request with 421 (Earss.MCP.Router passes an empty list
  # rather than ex_mcp's `:any` default), so the server looks up and the
  # agent cannot connect — a silent failure worth saying out loud at boot.
  defp warn_mcp_without_hosts do
    require Logger

    cfg = Application.get_env(:earss, :mcp, [])

    if Keyword.get(cfg, :enabled, false) == true and Keyword.get(cfg, :allowed_hosts, []) == [] do
      Logger.warning("""
      Earss: MCP is enabled but MCP_ALLOWED_HOSTS is empty.

      Every request to POST /mcp will be rejected with 421. Set
      MCP_ALLOWED_HOSTS to the hostname(s) your agent connects to, e.g.
      MCP_ALLOWED_HOSTS=localhost,127.0.0.1
      """)
    end

    :ok
  end

  defp env_or_config(env_name, config_key) do
    case System.get_env(env_name) do
      nil -> config() |> Keyword.get(config_key)
      "" -> config() |> Keyword.get(config_key)
      value -> value
    end
  end

  defp config, do: Application.get_env(:earss, :operator_auth, [])
end
