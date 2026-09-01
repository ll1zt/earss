defmodule Earss.MCP.Router do
  @moduledoc """
  Plug front door for the agent-facing MCP endpoint.

  `ExMCP.HttpPlug` speaks the protocol; this wrapper owns everything that is
  Earss policy:

    * **disabled means absent** — when `MCP_ENABLED` is false the endpoint
      returns 404 rather than 403, so a disabled server reveals nothing
    * **bearer authentication** — `MCP_API_KEY`, constant-time compared
    * **DNS-rebinding guards** — `:allowed_hosts` and `:allowed_origins`
      are passed through to ex_mcp. Its defaults are permissive (`:any`),
      which is exactly the configuration an attacker needs, so we require
      explicit values when the endpoint is enabled.
  """

  alias Earss.MCP.Auth

  @doc """
  Mount the MCP endpoint behind authentication, or 404 when disabled.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    if Auth.enabled?() do
      conn
      |> authenticate()
      |> maybe_dispatch(opts)
    else
      not_found(conn)
    end
  end

  defp authenticate(conn) do
    case Auth.verify(Auth.bearer_token(conn)) do
      :ok ->
        conn

      {:error, :missing_credential} ->
        # A deployment mistake, not a caller mistake: say so plainly, and
        # never treat "no key configured" as "no key required".
        conn
        |> json(500, %{
          error: "mcp_not_configured",
          message: "MCP is enabled but MCP_API_KEY is not set"
        })
        |> Plug.Conn.halt()

      {:error, :unauthorized} ->
        conn
        |> json(401, %{error: "unauthorized"})
        |> Plug.Conn.halt()
    end
  end

  defp maybe_dispatch(%{halted: true} = conn, _opts), do: conn

  defp maybe_dispatch(conn, opts) do
    ExMCP.HttpPlug.call(conn, ExMCP.HttpPlug.init(plug_opts(opts)))
  end

  defp plug_opts(opts) do
    Keyword.merge(
      [
        handler: Earss.MCP.Handler,
        server_info: %{name: "earss", version: "0.1.0"},
        # Serve MCP 2026-07-28 (per-request _meta, no initialize handshake)
        # while still answering legacy clients that open with initialize.
        protocol_mode: :prefer_modern,
        handler_call_timeout: 30_000
      ],
      security_opts() ++ opts
    )
  end

  # ex_mcp defaults `allowed_hosts` to `:any`, which accepts every Host
  # header — exactly the configuration a DNS-rebinding attack needs. It is
  # also the value used when the option is *absent*, so "no hosts configured"
  # and "every host allowed" are the same thing to ex_mcp.
  #
  # Both options are therefore passed unconditionally, with an empty list
  # standing for "nothing is allowed":
  #
  #   * `allowed_hosts: []` — every request is rejected (421), so an enabled
  #     endpoint with no configured host is unreachable rather than open
  #   * `allowed_origins: []` — any request carrying an Origin header is
  #     rejected (403), so no browser page can call the endpoint
  #
  # An empty list is a closed default, and the operator opens it deliberately
  # via MCP_ALLOWED_HOSTS / MCP_ALLOWED_ORIGINS. Startup warns when the
  # endpoint is enabled with no hosts (see Earss.OperatorAuth).
  defp security_opts do
    cfg = Application.get_env(:earss, :mcp, [])

    [
      allowed_hosts: Keyword.get(cfg, :allowed_hosts, []),
      allowed_origins: Keyword.get(cfg, :allowed_origins, [])
    ]
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp not_found(conn) do
    conn
    |> json(404, %{error: "not_found"})
    |> Plug.Conn.halt()
  end
end
