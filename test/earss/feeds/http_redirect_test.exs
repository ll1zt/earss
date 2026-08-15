defmodule Earss.Feeds.HTTPRedirectTest do
  use ExUnit.Case, async: false

  alias Earss.Feeds.HTTP

  describe "safe_redirect_target?/1" do
    defp fake_resolver do
      fn host ->
        case host do
          "good.example" -> {:ok, [{93, 184, 216, 34}]}
          "evil.example" -> {:ok, [{127, 0, 0, 1}]}
          "tailnet.example" -> {:ok, [{100, 100, 100, 1}]}
          "mixed.example" -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 1}]}
          "gone.example" -> {:error, :nxdomain}
          _ -> {:error, :nxdomain}
        end
      end
    end

    test "allows public IPs and public-resolving hostnames over http/https" do
      assert HTTP.safe_redirect_target?("http://93.184.216.34/a.xml")
      assert HTTP.safe_redirect_target?("https://good.example/feed.xml", fake_resolver())
    end

    test "rejects hostnames that resolve to blocked IPs" do
      refute HTTP.safe_redirect_target?("http://evil.example/x", fake_resolver())
      refute HTTP.safe_redirect_target?("http://tailnet.example/x", fake_resolver())
      # any blocked address in the set fails the target
      refute HTTP.safe_redirect_target?("http://mixed.example/x", fake_resolver())
    end

    test "real resolver rejects localhost (resolves to loopback)" do
      refute HTTP.safe_redirect_target?("http://localhost:4000/x")
    end

    test "unresolvable hosts pass (the fetch fails on its own)" do
      assert HTTP.safe_redirect_target?("http://gone.example/x", fake_resolver())
    end

    test "rejects non-http(s) schemes" do
      refute HTTP.safe_redirect_target?("file:///etc/passwd")
      refute HTTP.safe_redirect_target?("ftp://example.com/x")
      refute HTTP.safe_redirect_target?("gopher://example.com/x")
    end

    test "rejects blocked IPv4 literals" do
      for host <- [
            "127.0.0.1",
            "10.0.0.1",
            "100.64.0.1",
            "100.100.100.1",
            "169.254.169.254",
            "172.16.0.1",
            "192.168.1.1",
            "192.0.2.1",
            "198.18.0.1",
            "198.51.100.1",
            "203.0.113.1",
            "224.0.0.1",
            "240.0.0.1"
          ] do
        refute HTTP.safe_redirect_target?("http://#{host}/x"), "expected #{host} blocked"
      end
    end

    test "rejects blocked IPv6 literals" do
      for host <- ["::1", "::", "fd00::1", "fe80::1", "ff02::1", "::ffff:127.0.0.1"] do
        refute HTTP.safe_redirect_target?("http://[#{host}]/x"), "expected #{host} blocked"
      end
    end

    test "rejects garbage" do
      refute HTTP.safe_redirect_target?("")
      refute HTTP.safe_redirect_target?(nil)
      refute HTTP.safe_redirect_target?("not a url")
    end
  end

  describe "redirect handling (Bypass)" do
    setup do
      on_exit(fn -> Application.delete_env(:earss, :http) end)
      :ok
    end

    test "blocks a redirect to a loopback hostname (resolved)" do
      target = Bypass.open()

      source =
        Bypass.open()
        |> tap(fn b ->
          Bypass.expect(b, fn conn ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://localhost:#{target.port}/feed.xml")
            |> Plug.Conn.resp(302, "")
          end)
        end)

      assert {:error, {:http, {:blocked_redirect, "localhost"}}} =
               HTTP.get("http://localhost:#{source.port}/start")
    end

    test "blocks a redirect to a loopback literal" do
      source =
        Bypass.open()
        |> tap(fn b ->
          Bypass.expect(b, fn conn ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:9/feed.xml")
            |> Plug.Conn.resp(302, "")
          end)
        end)

      assert {:error, {:http, {:blocked_redirect, "127.0.0.1"}}} =
               HTTP.get("http://localhost:#{source.port}/start")
    end

    test "blocks a redirect to the tailnet CGNAT range" do
      source =
        Bypass.open()
        |> tap(fn b ->
          Bypass.expect(b, fn conn ->
            conn
            |> Plug.Conn.put_resp_header("location", "http://100.100.100.1:8080/internal")
            |> Plug.Conn.resp(302, "")
          end)
        end)

      assert {:error, {:http, {:blocked_redirect, "100.100.100.1"}}} =
               HTTP.get("http://localhost:#{source.port}/start")
    end

    test "caps the response body size" do
      Application.put_env(:earss, :http, max_body_bytes: 1_000)

      big =
        Bypass.open()
        |> tap(fn b ->
          Bypass.expect(b, fn conn -> Plug.Conn.resp(conn, 200, String.duplicate("a", 5_000)) end)
        end)

      assert {:error, {:http, :body_too_large}} =
               HTTP.get("http://localhost:#{big.port}/huge")
    end
  end
end
