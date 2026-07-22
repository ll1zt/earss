defmodule Earss.AdminTest do
  use Earss.ConnCase

  alias Earss.Reader
  alias Earss.API.Router

  setup do
    username = "adm_#{System.unique_integer([:positive])}"
    password = "secret"
    {:ok, user} = Reader.create_user(username, password)
    %{user: user, username: username, password: password}
  end

  defp admin_conn(method, path, body \\ nil, cookies \\ %{}) do
    body_bin =
      cond do
        is_nil(body) -> nil
        is_binary(body) -> body
        is_map(body) -> URI.encode_query(body)
      end

    conn =
      Plug.Test.conn(method, path, body_bin)
      |> Map.put(:host, "www.example.com")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])

    conn =
      if body_bin do
        Plug.Conn.put_req_header(conn, "content-type", "application/x-www-form-urlencoded")
      else
        conn
      end

    conn =
      Enum.reduce(cookies, conn, fn {k, v}, c ->
        Plug.Test.put_req_cookie(c, k, v)
      end)

    Router.call(conn, Router.init([]))
  end

  defp login(username, password) do
    conn =
      admin_conn(:post, "/admin/login", %{
        "username" => username,
        "password" => password
      })

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/admin"]
    # recycle cookies for next request
    Plug.Test.conn(:get, "/")
    |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
    |> Plug.Test.recycle_cookies(conn)
  end

  test "login required for admin home" do
    conn = admin_conn(:get, "/admin")
    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/admin/login"]
  end

  test "login and dashboard", %{username: username, password: password} do
    base = login(username, password)

    conn =
      Plug.Test.conn(:get, "/admin")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Test.recycle_cookies(base)
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "Dashboard"
    assert conn.resp_body =~ username
    assert conn.resp_body =~ "/fever/"
  end

  test "subscribe via admin form", %{username: username, password: password} do
    base = login(username, password)

    link = "https://example.com/admin_#{System.unique_integer([:positive])}.xml"

    conn =
      Plug.Test.conn(
        :post,
        "/admin/subscriptions",
        URI.encode_query(%{
          "link" => link,
          "title" => "Admin Feed",
          "refresh" => "false"
        })
      )
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Test.recycle_cookies(base)
      |> Router.call(Router.init([]))

    assert conn.status == 302

    conn =
      Plug.Test.conn(:get, "/admin/subscriptions")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Test.recycle_cookies(conn)
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ link
  end

  test "bad login", %{username: username} do
    conn =
      admin_conn(:post, "/admin/login", %{
        "username" => username,
        "password" => "wrong"
      })

    assert conn.status == 200
    assert conn.resp_body =~ "Invalid"
  end
end
