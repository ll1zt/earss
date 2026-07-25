defmodule Earss.AdminTest do
  use Earss.ConnCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.API.Router
  alias Earss.Repo

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

  defp extract_csrf(html) when is_binary(html) do
    case Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, html) do
      [_, token] -> token
      _ -> nil
    end
  end

  defp extract_csrf(_), do: nil

  defp extract_csrf!(html) do
    extract_csrf(html) || flunk("missing CSRF token in HTML")
  end

  defp login(username, password) do
    login_page = admin_conn(:get, "/admin/login")
    assert login_page.status == 200
    token = extract_csrf!(login_page.resp_body)

    conn =
      Plug.Test.conn(
        :post,
        "/admin/login",
        URI.encode_query(%{
          "_csrf_token" => token,
          "username" => username,
          "password" => password
        })
      )
      |> Map.put(:host, "www.example.com")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Test.recycle_cookies(login_page)
      |> Router.call(Router.init([]))

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/admin"]

    Plug.Test.conn(:get, "/")
    |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
    |> Plug.Test.recycle_cookies(conn)
  end

  defp authed_get(base, path) do
    Plug.Test.conn(:get, path)
    |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
    |> Plug.Test.recycle_cookies(base)
    |> Router.call(Router.init([]))
  end

  defp page_with_csrf(base) do
    case extract_csrf(Map.get(base, :resp_body)) do
      token when is_binary(token) and token != "" -> base
      _ -> authed_get(base, "/admin")
    end
  end

  defp authed_post(base, path, params) do
    page = page_with_csrf(base)
    token = extract_csrf!(page.resp_body)
    params = Map.put(params, "_csrf_token", token)

    Plug.Test.conn(:post, path, URI.encode_query(params))
    |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Plug.Test.recycle_cookies(page)
    |> Router.call(Router.init([]))
  end

  test "login required for admin home" do
    conn = admin_conn(:get, "/admin")
    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/admin/login"]
  end

  test "login and dashboard", %{username: username, password: password} do
    base = login(username, password)
    conn = authed_get(base, "/admin")

    assert conn.status == 200
    assert conn.resp_body =~ "Dashboard"
    assert conn.resp_body =~ username
    assert conn.resp_body =~ "/fever/"
    assert conn.resp_body =~ "Due now"
    assert conn.resp_body =~ ~s(href="/admin/system")
    assert conn.resp_body =~ ~s(data-theme="crt")
    assert conn.resp_body =~ "theme-switch"
  end

  test "switch admin theme via POST", %{username: username, password: password} do
    base = login(username, password)
    dash = authed_get(base, "/admin")
    assert dash.resp_body =~ ~s(data-theme="crt")

    conn =
      authed_post(dash, "/admin/theme", %{
        "theme" => "paper"
      })

    assert conn.status == 302

    page = authed_get(conn, "/admin")
    assert page.status == 200
    assert page.resp_body =~ ~s(data-theme="paper")
    assert page.resp_body =~ "admin-theme--paper"
  end

  test "sources page lists native adapter", %{username: username, password: password} do
    base = login(username, password)
    conn = authed_get(base, "/admin/sources")

    assert conn.status == 200
    assert conn.resp_body =~ "Registered adapters"
    assert conn.resp_body =~ "native"
    assert conn.resp_body =~ "Subscribe by URL"
    assert conn.resp_body =~ ~s(href="/admin/sources")
  end

  test "sources subscribe via earss URL with stub adapter", %{
    username: username,
    password: password
  } do
    assert :ok = Earss.SourceStub.ensure_registered()
    base = login(username, password)

    conn =
      authed_post(base, "/admin/sources/subscribe", %{
        "link" => "earss://stub/ping/admin_s5",
        "refresh" => "false"
      })

    assert conn.status == 302
    [loc] = Plug.Conn.get_resp_header(conn, "location")
    assert loc =~ ~r{^/admin/subscriptions/\d+$}

    page = authed_get(conn, loc)
    assert page.status == 200
    assert page.resp_body =~ "earss://stub/ping/admin_s5"
    assert page.resp_body =~ "stub"
  end

  test "sources subscribe via route params", %{username: username, password: password} do
    assert :ok = Earss.SourceStub.ensure_registered()
    base = login(username, password)

    conn =
      authed_post(base, "/admin/sources/subscribe", %{
        "adapter_id" => "stub",
        "path" => "ping/:name",
        "param_name" => "from_route",
        "refresh" => "false"
      })

    assert conn.status == 302
    [loc] = Plug.Conn.get_resp_header(conn, "location")
    assert loc =~ ~r{^/admin/subscriptions/\d+$}

    page = authed_get(conn, loc)
    assert page.resp_body =~ "earss://stub/ping/from_route"
  end

  test "subscribe via admin form", %{username: username, password: password} do
    base = login(username, password)

    link = "https://example.com/admin_#{System.unique_integer([:positive])}.xml"

    conn =
      authed_post(base, "/admin/subscriptions", %{
        "link" => link,
        "title" => "Admin Feed",
        "refresh" => "false"
      })

    assert conn.status == 302
    [loc] = Plug.Conn.get_resp_header(conn, "location")
    assert loc =~ ~r{^/admin/subscriptions/\d+$}

    conn = authed_get(conn, loc)
    assert conn.status == 200
    assert conn.resp_body =~ link
    assert conn.resp_body =~ "Your subscription"
  end

  test "edit subscription and filter list", %{
    user: user,
    username: username,
    password: password
  } do
    base = login(username, password)

    {:ok, cat} = Reader.create_category(user, %{name: "News"})

    link = "https://example.com/edit_#{System.unique_integer([:positive])}.xml"

    {:ok, sub} =
      Reader.subscribe(user, %{
        "link" => link,
        "title" => "Original",
        "refresh" => false
      })

    conn =
      authed_post(base, "/admin/subscriptions/#{sub.id}", %{
        "custom_title" => "Renamed Feed",
        "custom_refresh_interval" => "45",
        "category_id" => to_string(cat.id),
        "is_hidden" => "true"
      })

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/admin/subscriptions/#{sub.id}"]

    updated = Repo.get!(Earss.Reader.Subscription, sub.id)
    assert updated.custom_title == "Renamed Feed"
    assert updated.custom_refresh_interval == 45
    assert updated.category_id == cat.id
    assert updated.is_hidden == true

    conn = authed_get(conn, "/admin/subscriptions/#{sub.id}")
    assert conn.status == 200
    assert conn.resp_body =~ "Renamed Feed"
    assert conn.resp_body =~ "45"

    conn = authed_get(conn, "/admin/subscriptions?q=Renamed&status=hidden")
    assert conn.status == 200
    assert conn.resp_body =~ "Renamed Feed"
    assert conn.resp_body =~ link

    conn = authed_get(conn, "/admin/subscriptions?q=no-such-feed-xyz")
    assert conn.status == 200
    assert conn.resp_body =~ "No subscriptions match"
  end

  test "feeds health filter and system admin-only", %{
    user: user,
    username: username,
    password: password
  } do
    base = login(username, password)

    link = "https://example.com/feed_#{System.unique_integer([:positive])}.xml"

    {:ok, sub} =
      Reader.subscribe(user, %{
        "link" => link,
        "title" => "Broken",
        "refresh" => false
      })

    feed = Feeds.get_feed(sub.feed_id)

    {:ok, _} =
      Feeds.update_feed(feed, %{
        is_active: false,
        error_count: 5,
        last_error: "timeout"
      })

    conn = authed_get(base, "/admin/feeds?status=disabled")
    assert conn.status == 200
    assert conn.resp_body =~ link
    assert conn.resp_body =~ "disabled"
    assert conn.resp_body =~ "Refresh selected"

    conn = authed_get(conn, "/admin/system")
    assert conn.status == 200
    assert conn.resp_body =~ "Retention"
    assert conn.resp_body =~ "Config (read-only)"

    conn = authed_post(conn, "/admin/system/retention", %{"mode" => "dry_run"})
    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/admin/system"]

    # sub_user cannot open system
    sub_name = "sub_#{System.unique_integer([:positive])}"
    {:ok, _} = Reader.create_sub_user(sub_name, "secret")
    sub_base = login(sub_name, "secret")
    conn = authed_get(sub_base, "/admin/system")
    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/admin"]
  end

  test "category rename", %{user: user, username: username, password: password} do
    base = login(username, password)
    {:ok, cat} = Reader.create_category(user, %{name: "Old", position: 1})

    conn =
      authed_post(base, "/admin/categories/#{cat.id}", %{
        "name" => "New Name",
        "position" => "3"
      })

    assert conn.status == 302
    updated = Reader.get_category(cat.id)
    assert updated.name == "New Name"
    assert updated.position == 3
  end

  test "bad login", %{username: username} do
    login_page = admin_conn(:get, "/admin/login")
    token = extract_csrf!(login_page.resp_body)

    conn =
      Plug.Test.conn(
        :post,
        "/admin/login",
        URI.encode_query(%{
          "_csrf_token" => token,
          "username" => username,
          "password" => "wrong"
        })
      )
      |> Map.put(:host, "www.example.com")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Test.recycle_cookies(login_page)
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "Invalid"
  end

  test "POST without CSRF is rejected", %{username: username, password: password} do
    base = login(username, password)
    page = authed_get(base, "/admin")

    conn =
      Plug.Test.conn(
        :post,
        "/admin/subscriptions",
        URI.encode_query(%{
          "link" => "https://example.com/csrf_#{System.unique_integer([:positive])}.xml",
          "refresh" => "false"
        })
      )
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Test.recycle_cookies(page)
      |> Router.call(Router.init([]))

    assert conn.status == 302
    # must not create a subscription
    assert Reader.list_subscriptions(
             Reader.get_user_by_username(username)
           ) == []
  end

  test "login form embeds CSRF token" do
    conn = admin_conn(:get, "/admin/login")
    assert conn.status == 200
    assert conn.resp_body =~ ~s(name="_csrf_token")
  end
end
