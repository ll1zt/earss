defmodule Earss.AdminTest do
  use Earss.ConnCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.API.Router
  alias Earss.Repo

  setup do
    :ok
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

  defp login do
    login_page = admin_conn(:get, "/admin/login")
    assert login_page.status == 200
    token = extract_csrf!(login_page.resp_body)

    conn =
      Plug.Test.conn(
        :post,
        "/admin/login",
        URI.encode_query(%{
          "_csrf_token" => token,
          "password" => "test-password"
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

  test "login and dashboard" do
    base = login()
    conn = authed_get(base, "/admin")

    assert conn.status == 200
    assert conn.resp_body =~ "Dashboard"
    assert conn.resp_body =~ "earss"
    assert conn.resp_body =~ "/fever/"
    assert conn.resp_body =~ "Due now"
    assert conn.resp_body =~ ~s(href="/admin/system")
    assert conn.resp_body =~ ~s(data-theme="crt")
    assert conn.resp_body =~ "theme-switch"
  end

  test "switch admin theme via POST" do
    base = login()
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

  test "sources page lists native adapter" do
    base = login()
    conn = authed_get(base, "/admin/sources")

    assert conn.status == 200
    assert conn.resp_body =~ "Registered adapters"
    assert conn.resp_body =~ "native"
    assert conn.resp_body =~ "Subscribe by URL"
    assert conn.resp_body =~ ~s(href="/admin/sources")
  end

  test "sources subscribe via earss URL with stub adapter" do
    assert :ok = Earss.SourceStub.ensure_registered()
    base = login()

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

  test "sources subscribe via route params" do
    assert :ok = Earss.SourceStub.ensure_registered()
    base = login()

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

  test "subscribe via admin form" do
    base = login()

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

  test "edit subscription and filter list" do
    base = login()

    {:ok, cat} = Reader.create_category(%{name: "News"})

    link = "https://example.com/edit_#{System.unique_integer([:positive])}.xml"

    {:ok, sub} =
      Reader.subscribe(%{
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

  test "feeds health filter and system admin-only" do
    base = login()

    link = "https://example.com/feed_#{System.unique_integer([:positive])}.xml"

    {:ok, sub} =
      Reader.subscribe(%{
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

    # the single operator has full system access
    conn = authed_get(conn, "/admin/system")
    assert conn.status == 200
  end

  test "category rename" do
    base = login()
    {:ok, cat} = Reader.create_category(%{name: "Old", position: 1})

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

  test "bad login" do
    login_page = admin_conn(:get, "/admin/login")
    token = extract_csrf!(login_page.resp_body)

    conn =
      Plug.Test.conn(
        :post,
        "/admin/login",
        URI.encode_query(%{
          "_csrf_token" => token,
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

  test "POST without CSRF is rejected" do
    base = login()
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
    assert Reader.list_subscriptions() == []
  end

  test "login form embeds CSRF token" do
    conn = admin_conn(:get, "/admin/login")
    assert conn.status == 200
    assert conn.resp_body =~ ~s(name="_csrf_token")
  end

  describe "export" do
    defp unique_link do
      "https://example.com/exp_#{System.unique_integer([:positive])}.xml"
    end

    defp seed_starred!() do
      link = unique_link()
      {:ok, feed} = Feeds.create_feed(%{link: link, title: "Admin Export Feed"})
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

      {:ok, _} =
        Feeds.upsert_entry(feed, %{
          link: "#{link}/1",
          guid: "g1",
          title: "Admin One",
          content: "<p>Admin body</p>"
        })

      [entry] = Repo.all(Earss.Feeds.Entry)
      {:ok, _} = Reader.set_star(entry.id, true)
      feed
    end

    test "export page renders download links" do
      base = login()
      conn = authed_get(base, "/admin/export")

      assert conn.status == 200
      assert conn.resp_body =~ "Starred entries"
      assert conn.resp_body =~ "/admin/export/starred?format=markdown"
      assert conn.resp_body =~ "/admin/export/starred?format=json"
      assert conn.resp_body =~ "Full archive (admin)"
      assert conn.resp_body =~ "/admin/export/all?format=markdown"
      assert conn.resp_body =~ "/admin/opml/export"
    end

    test "export page shows the full archive to the operator" do
      base = login()
      conn = authed_get(base, "/admin/export")

      assert conn.status == 200
      assert conn.resp_body =~ "Starred entries"
      assert conn.resp_body =~ "Full archive (admin)"
    end

    test "starred download renders markdown" do
      seed_starred!()
      base = login()

      conn = authed_get(base, "/admin/export/starred?format=markdown")
      assert conn.status == 200
      assert conn.resp_body =~ "## Admin One"
      assert conn.resp_body =~ "Admin body"
      refute conn.resp_body =~ "<p>"

      [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    test "all download requires admin" do
      seed_starred!()
      base = login()

      conn = authed_get(base, "/admin/export/all?format=json")
      assert conn.status == 200
      assert length(Jason.decode!(conn.resp_body)["entries"]) == 1
    end

    test "export routes require login" do
      conn = admin_conn(:get, "/admin/export")
      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "location") == ["/admin/login"]
    end
  end
end

defmodule Earss.AdminTranslationTest do
  use Earss.ConnCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.API.Router
  alias Earss.Repo
  alias Earss.Feeds.Feed
  alias Earss.Reader.Subscription
  alias Earss.Test.FakeTranslator

  setup do
    # admin translation forms render only when a translator plugin is loaded
    id = "aaa_admintr_#{System.unique_integer([:positive])}"
    assert :ok == Earss.Enrichment.Registry.register(%{id: id, module: FakeTranslator})
    on_exit(fn -> Earss.Enrichment.Registry.unregister(id) end)
    :ok
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

  defp login do
    login_page = admin_conn(:get, "/admin/login")
    token = extract_csrf(login_page.resp_body)

    conn =
      Plug.Test.conn(
        :post,
        "/admin/login",
        URI.encode_query(%{
          "_csrf_token" => token,
          "password" => "test-password"
        })
      )
      |> Map.put(:host, "www.example.com")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Test.recycle_cookies(login_page)
      |> Router.call(Router.init([]))

    Plug.Test.conn(:get, "/")
    |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
    |> Plug.Test.recycle_cookies(conn)
  end

  defp csrf_page(base, page_path) do
    page = authed_get(base, page_path)
    token = extract_csrf(page.resp_body) || flunk("missing csrf token")
    {token, page}
  end

  defp csrf_post(base, page_path, post_path, body) do
    {token, page_conn} = csrf_page(base, page_path)
    body = Map.put(body, "_csrf_token", token)

    Plug.Test.conn(:post, post_path, URI.encode_query(body))
    |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Plug.Test.recycle_cookies(page_conn)
    |> Router.call(Router.init([]))
  end

  test "subscription page shows translation forms" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/atr_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, sub} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
    conn = login()

    page = authed_get(conn, "/admin/subscriptions/#{sub.id}")
    assert page.status == 200

    html = page.resp_body
    refute html =~ "/admin/subscriptions/#{sub.id}/translation"
    assert html =~ "/admin/subscriptions/#{sub.id}/feed_translation"
    refute html =~ "backfill"
    assert html =~ "name=\"feed_translate_to\""
    assert html =~ "name=\"feed_original_layout\""
  end

  defp authed_get(base, path) do
    Plug.Test.conn(:get, path)
    |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
    |> Plug.Test.recycle_cookies(base)
    |> Router.call(Router.init([]))
  end

  test "feed translation updates the shared feed config" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/atr_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, sub} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
    conn = login()

    resp =
      csrf_post(
        conn,
        "/admin/subscriptions/#{sub.id}",
        "/admin/subscriptions/#{sub.id}/feed_translation",
        %{feed_translate_to: "zh", feed_translate_from: "en", feed_original_layout: "section"}
      )

    assert resp.status == 302
    updated = Repo.get!(Feed, feed.id)
    assert updated.translate_to == "zh"
    assert updated.translate_from == "en"
    assert updated.original_layout == "section"
  end

  test "feed translation update clears pending when disabled" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/atr_#{System.unique_integer([:positive])}.xml",
        translate_to: "zh"
      })

    {:ok, sub} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
    conn = login()

    resp =
      csrf_post(
        conn,
        "/admin/subscriptions/#{sub.id}",
        "/admin/subscriptions/#{sub.id}/feed_translation",
        %{feed_translate_to: ""}
      )

    assert resp.status == 302
    assert Repo.get!(Feed, feed.id).translate_to == nil
  end

  test "category apply sets feed translation for all feeds in the category" do
    {:ok, cat} = Reader.create_category(%{name: "Tech"})

    {:ok, f1} =
      Feeds.create_feed(%{
        link: "https://example.com/atr_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, f2} =
      Feeds.create_feed(%{
        link: "https://example.com/atr_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, _} = Reader.subscribe(%{feed_id: f1.id, category_id: cat.id, refresh: false})
    {:ok, _} = Reader.subscribe(%{feed_id: f2.id, category_id: cat.id, refresh: false})

    conn = login()

    resp =
      csrf_post(conn, "/admin/categories", "/admin/categories/#{cat.id}/translation", %{
        translate_to: "ja"
      })

    assert resp.status == 302

    assert Repo.get!(Feed, f1.id).translate_to == "ja"
    assert Repo.get!(Feed, f2.id).translate_to == "ja"
  end

  test "translate status page renders" do
    conn = login()
    page = authed_get(conn, "/admin/translate")
    assert page.status == 200
    assert page.resp_body =~ "Translation plugin"
  end

  test "translate page shows per-feed translated counts" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/atr_#{System.unique_integer([:positive])}.xml",
        translate_to: "zh"
      })

    {:ok, entry} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/atr/1",
        guid: "atr-1",
        title: "T",
        content: "<p>B</p>"
      })

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    %Earss.Feeds.EntryTranslation{}
    |> Earss.Feeds.EntryTranslation.changeset(%{
      entry_id: entry.id,
      lang: "zh",
      title: "译",
      original_hash: entry.content_hash,
      model: "test",
      translated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    conn = login()
    page = authed_get(conn, "/admin/translate")
    assert page.status == 200
    assert page.resp_body =~ "Translated"
    assert page.resp_body =~ "zh 1/1"
  end

  test "unsubscribed translated feeds no longer appear on the translate page" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/atr_#{System.unique_integer([:positive])}.xml",
        translate_to: "zh"
      })

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
    {:ok, _} = Reader.unsubscribe(feed.id)

    conn = login()
    page = authed_get(conn, "/admin/translate")
    assert page.status == 200
    refute page.resp_body =~ feed.link
  end
end
