defmodule Earss.MCP.Tools.System do
  @moduledoc """
  Health and status tools: the read-only surface an agent uses to confirm the
  server is up and to understand what it is allowed to do.

  Kept deliberately small in the first milestone — `ping` is the smoke test
  for the whole transport (discovery, tool listing, invocation). Status and
  metrics tools land with the query surface.
  """

  alias Earss.MCP.Auth
  alias Earss.MCP.Tool

  @doc """
  Every tool this module contributes.
  """
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new(
        name: "ping",
        description:
          "Health check. Returns the server name, the MCP protocol versions " <>
            "this server supports, and whether it is currently restricted to " <>
            "read-only tools.",
        mutating: false,
        handler: &ping/1
      )
    ]
  end

  defp ping(_args) do
    {:ok,
     %{
       server: "earss",
       ok: true,
       protocol_versions: ["2026-07-28"],
       read_only: Auth.read_only?()
     }}
  end
end
