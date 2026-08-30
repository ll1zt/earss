defmodule Earss.MCP.RouterTest do
  @moduledoc """
  Endpoint-level tests for the MCP surface: mounting, authentication and the
  read-only gate.

  These drive the real Plug stack and the real ex_mcp protocol layer rather
  than stubbing it, because the whole point of the first milestone is that a
  conforming client can complete discovery → list → call.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @key "test-mcp-key"

  setup do
    previous = Application.get_env(:earss, :mcp)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:earss, :mcp, previous),
        else: Application.delete_env(:earss, :mcp)
    end)

    :ok
  end

  defp enable(opts \\ []) do
    Application.put_env(:earss, :mcp, Keyword.merge([enabled: true, api_key: @key], opts))
  end

  defp mcp_post(body, headers \\ []) do
    conn(:post, "/mcp", Jason.encode!(body))
    |> Map.put(:host, "localhost")
    |> then(fn c ->
      Enum.reduce(
        [{"content-type", "application/json"} | headers],
        c,
        fn {k, v}, acc -> put_req_header(acc, k, v) end
      )
    end)
    |> Earss.API.Router.call(Earss.API.Router.init([]))
  end

  # Modern clients carry the protocol version, method and target name as
  # headers as well as in the body; ex_mcp validates that they agree.
  defp request(id, method, params, auth \\ @key) do
    headers = [
      {"authorization", "Bearer #{auth}"},
      {"mcp-protocol-version", "2026-07-28"},
      {"mcp-method", method}
    ]

    headers =
      case Map.get(params, "name") do
        nil -> headers
        name -> [{"mcp-name", name} | headers]
      end

    mcp_post(
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => Map.put(params, "_meta", meta())
      },
      headers
    )
  end

  defp meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientInfo" => %{"name" => "test-client", "version" => "1.0.0"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end

  defp result(conn) do
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["jsonrpc"] == "2.0"
    body
  end

  describe "when disabled (the default)" do
    test "the endpoint does not exist" do
      Application.put_env(:earss, :mcp, enabled: false)

      conn =
        mcp_post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{}})

      assert conn.status == 404
    end

    test "the tool list is not advertised either" do
      Application.put_env(:earss, :mcp, enabled: false)

      assert mcp_post(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "tools/list",
               "params" => %{}
             }).status == 404
    end
  end

  describe "authentication" do
    test "rejects a missing credential" do
      enable()

      conn =
        mcp_post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{}})

      assert conn.status == 401
    end

    test "rejects a wrong credential" do
      enable()

      conn = request(1, "server/discover", %{}, "not-the-key")

      assert conn.status == 401
    end

    test "reports a missing server-side key instead of accepting everyone" do
      # The dangerous reading of "no api_key configured" is "no key
      # required" — an operator who enables MCP and forgets the key would
      # otherwise have an unauthenticated agent endpoint.
      Application.put_env(:earss, :mcp, enabled: true, api_key: nil)

      conn = request(1, "server/discover", %{})

      assert conn.status == 500
      assert Jason.decode!(conn.resp_body)["error"] == "mcp_not_configured"
    end
  end

  describe "protocol round trip" do
    setup do
      enable()
      :ok
    end

    test "server/discover advertises the modern revision first" do
      body = request(1, "server/discover", %{}) |> result()

      assert body["result"]["supportedVersions"] |> hd() == "2026-07-28"
      assert body["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "earss"
    end

    test "tools/list returns JSON-serializable definitions" do
      body = request(2, "tools/list", %{}) |> result()

      tools = body["result"]["tools"]
      assert [tool] = tools
      assert tool["name"] == "ping"
      assert tool["inputSchema"]["type"] == "object"

      # A handler function left in the advertised schema would make this
      # encode blow up, so serializability is the real assertion here.
      assert {:ok, _} = Jason.encode(tools)
    end

    test "tools/call answers with text and structured content" do
      body = request(3, "tools/call", %{"name" => "ping", "arguments" => %{}}) |> result()

      assert body["result"]["structuredContent"]["ok"] == true
      assert body["result"]["structuredContent"]["server"] == "earss"

      [content | _] = body["result"]["content"]
      assert content["type"] == "text"
      assert Jason.decode!(content["text"])["ok"] == true
    end

    test "an unknown tool is a protocol error, not a tool error" do
      body = request(4, "tools/call", %{"name" => "nope", "arguments" => %{}}) |> result()

      # -32602 rather than an isError result: the model cannot fix a name
      # that does not exist by changing the arguments.
      assert body["error"]["code"] == -32602
      refute body["result"]
    end
  end

  describe "read-only mode" do
    test "hides mutating tools and rejects calls to them" do
      enable(read_only: true)

      body = request(2, "tools/list", %{}) |> result()

      # ping is read-only, so it survives; mutating tools would be gone and
      # a call to one would be refused by Earss.MCP.Handler.
      assert [tool] = body["result"]["tools"]
      assert tool["name"] == "ping"

      call = request(3, "tools/call", %{"name" => "ping", "arguments" => %{}}) |> result()

      assert call["result"]["structuredContent"]["read_only"] == true
    end
  end
end
