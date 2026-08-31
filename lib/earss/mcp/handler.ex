defmodule Earss.MCP.Handler do
  @moduledoc """
  MCP tool surface for AI agents.

  This is the fourth protocol adapter, alongside `Earss.API.JSON`,
  `Earss.Fever` and `Earss.API.GReader` — it exposes what the operator can
  already do and nothing more. Following the same rule as the other
  adapters (`docs/development.md`): **call the context facades, never `Repo`
  or the schemas directly**, so a query exists in exactly one place.

  Tools are grouped by module and merged into one flat list, which the MCP
  2026-07-28 spec requires to be deterministic — a stable order lets clients
  cache the list and keeps LLM prompt-cache hit rates high.

  Read-only mode (`MCP_READ_ONLY=true`) hides every mutating tool and
  rejects calls to them, so an agent can browse the library safely.
  """

  use ExMCP.Server.Handler

  alias Earss.MCP.Tool
  alias Earss.MCP.Tools.Backfill
  alias Earss.MCP.Tools.Categories
  alias Earss.MCP.Tools.Ingest
  alias Earss.MCP.Tools.Opml
  alias Earss.MCP.Tools.Pipelines
  alias Earss.MCP.Tools.ReadBatch
  alias Earss.MCP.Tools.Reading
  alias Earss.MCP.Tools.Status
  alias Earss.MCP.Tools.Subscriptions
  alias Earss.MCP.Tools.System

  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_list_tools(_cursor, state) do
    tools =
      all_tools()
      |> Enum.filter(&visible?/1)
      |> Enum.map(&Tool.definition/1)

    {:ok, tools, nil, state}
  end

  @impl true
  def handle_call_tool(name, arguments, state) do
    with {:ok, tool} <- fetch_tool(name),
         :ok <- require_writable(tool) do
      if tool.destructive do
        invoke_destructive(tool, arguments, state)
      else
        invoke(tool, arguments, state)
      end
    else
      {:error, :unknown_tool} ->
        # Unknown tool is a protocol error, not a tool execution error: the
        # model cannot fix a name that does not exist by retrying with
        # different arguments.
        {:error, "unknown tool: #{name}", state}

      {:error, :read_only} ->
        {:error, "server is read-only; #{name} is a mutating tool", state}
    end
  end

  ## Tool registry

  # Fixed order: the spec requires tools/list to be deterministic so clients
  # can cache it and LLM prompt caches keep hitting.
  defp all_tools do
    Reading.tools() ++
      Ingest.tools() ++
      Backfill.tools() ++
      Subscriptions.tools() ++
      Categories.tools() ++
      Opml.tools() ++
      ReadBatch.tools() ++
      Pipelines.tools() ++
      Status.tools() ++
      System.tools()
  end

  defp fetch_tool(name) do
    case Enum.find(all_tools(), &(&1.name == name)) do
      nil -> {:error, :unknown_tool}
      tool -> {:ok, tool}
    end
  end

  defp invoke(tool, arguments, state) do
    case tool.handler.(arguments) do
      {:ok, payload} ->
        {:ok, text_result(payload), state}

      {:error, reason} ->
        # Tool *execution* errors (as opposed to protocol errors) carry
        # actionable feedback the model can act on, so they come back as
        # isError results rather than JSON-RPC errors.
        {:ok, error_result(reason), state}
    end
  end

  ## Two-phase execution for destructive tools

  # A destructive tool called without `confirm: true` returns an impact
  # report instead of acting. This is the server-side half of the safety
  # model: client-side confirmation prompts are optional — many clients
  # ignore the annotations — so the server must not rely on them.
  #
  # The report comes from the tool's own :impact callback (only the tool
  # knows what it would affect: which rows, how many, what is dropped);
  # a tool without one gets a generic marker report. Either way the response
  # says explicitly that nothing has been done yet.
  defp invoke_destructive(tool, arguments, state) do
    if confirm?(arguments) do
      invoke(tool, Map.delete(arguments, "confirm"), state)
    else
      {:ok, text_result(impact_report(tool, arguments)), state}
    end
  end

  defp confirm?(%{"confirm" => true}), do: true
  defp confirm?(%{"confirm" => "true"}), do: true
  defp confirm?(_), do: false

  defp impact_report(tool, arguments) do
    impact =
      case tool.impact do
        fun when is_function(fun, 1) ->
          safe_impact(tool, fun, Map.delete(arguments, "confirm"))

        _ ->
          %{}
      end

    Map.merge(
      %{tool: tool.name, executed: false, requires_confirmation: true},
      impact
    )
  end

  # An impact probe should never take down the confirmation response: a
  # failure degrades to a generic report, and the model can still confirm.
  defp safe_impact(_tool, fun, args) do
    fun.(args)
  rescue
    e ->
      %{impact_error: "could not compute impact: #{Exception.message(e)}"}
  end

  ## Read-only gate

  defp require_writable(tool) do
    if tool.mutating and Earss.MCP.Auth.read_only?(), do: {:error, :read_only}, else: :ok
  end

  defp visible?(tool) do
    not (Earss.MCP.Auth.read_only?() and tool.mutating)
  end

  ## Result shaping

  # Structured content is also mirrored into a text block: per the spec, a
  # tool that returns structured content SHOULD include the serialized JSON
  # so clients that only read `content` still see it.
  defp text_result(payload) when is_binary(payload), do: %{"content" => [text(payload)]}

  defp text_result(payload) when is_map(payload) do
    %{
      "content" => [text(Jason.encode!(payload))],
      "structuredContent" => payload
    }
  end

  defp error_result(reason) do
    %{
      "content" => [text("error: #{format_reason(reason)}")],
      "isError" => true
    }
  end

  defp text(str), do: %{"type" => "text", "text" => str}

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
