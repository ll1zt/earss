defmodule Earss.APITest do
  use Earss.ConnCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.Feeds.HTTPStub

  setup do
    {:ok, user} = Reader.create_user("api_#{System.unique_integer([:positive])}", "secret")
    token = login_token(user.username, "secret")
    %{user: user, token: token}
  end

  test "health" do
    conn = json_req(:get, "/health")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "ok"
  end

  test "login rejects bad password", %{user: user} do
    conn = json_req(:post, "/api/auth/login", %{username: user.username, password: "nope"})
    assert conn.status == 401
  end

  test "me requires auth" do
    conn = json_req(:get, "/api/me")
    assert conn.status == 401
  end

  test "me with token", %{user: user, token: token} do
    conn = json_req(:get, "/api/me", nil, auth_header(token))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["user"]["username"] == user.username
  end

  test "categories CRUD", %{token: token} do
    conn =
      json_req(:post, "/api/categories", %{name: "News", position: 1}, auth_header(token))

    assert conn.status == 201
    id = Jason.decode!(conn.resp_body)["category"]["id"]

    conn = json_req(:get, "/api/categories", nil, auth_header(token))
    assert conn.status == 200
    assert length(Jason.decode!(conn.resp_body)["categories"]) == 1

    conn = json_req(:patch, "/api/categories/#{id}", %{name: "Tech"}, auth_header(token))
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["category"]["name"] == "Tech"

    conn = json_req(:delete, "/api/categories/#{id}", nil, auth_header(token))
    assert conn.status == 200
  end

  test "subscribe list entries mark read", %{token: token} do
    previous = Application.get_env(:earss, :http_client)
    Application.put_env(:earss, :http_client, HTTPStub)

    on_exit(fn ->
      HTTPStub.clear()

      if previous do
        Application.put_env(:earss, :http_client, previous)
      else
        Application.delete_env(:earss, :http_client)
      end
    end)

    body = File.read!(Path.join([File.cwd!(), "test/fixtures/feeds/sample.rss.xml"]))

    HTTPStub.put(fn _url, _opts ->
      {:ok, %{status: 200, body: body, etag: nil, last_modified: nil}}
    end)

    conn =
      json_req(
        :post,
        "/api/subscriptions",
        %{link: "https://example.com/api-feed.xml", title: "API Feed", refresh: true},
        auth_header(token)
      )

    assert conn.status == 201
    sub = Jason.decode!(conn.resp_body)["subscription"]
    assert sub["feed"]["link"] == "https://example.com/api-feed.xml"

    conn = json_req(:get, "/api/entries?unread=true", nil, auth_header(token))
    assert conn.status == 200
    entries = Jason.decode!(conn.resp_body)["entries"]
    assert length(entries) >= 1

    entry_id = hd(entries)["id"]

    conn = json_req(:post, "/api/entries/#{entry_id}/read", nil, auth_header(token))
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["state"]["is_read"] == true

    conn = json_req(:get, "/api/entries?unread=true", nil, auth_header(token))
    unread_ids = Jason.decode!(conn.resp_body)["entries"] |> Enum.map(& &1["id"])
    refute entry_id in unread_ids

    conn = json_req(:post, "/api/entries/#{entry_id}/star", nil, auth_header(token))
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["state"]["is_star"] == true
  end

  test "subscribe without refresh", %{token: token} do
    conn =
      json_req(
        :post,
        "/api/subscriptions",
        %{
          link: "https://example.com/no-refresh-#{System.unique_integer([:positive])}.xml",
          refresh: false
        },
        auth_header(token)
      )

    assert conn.status == 201
  end

  test "opml import export and mark_read", %{token: token} do
    opml = File.read!(Path.join([File.cwd!(), "test/fixtures/opml/sample.opml"]))

    conn =
      json_req(
        :post,
        "/api/opml/import",
        %{opml: opml, refresh: false},
        auth_header(token)
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["imported"] == 3

    conn = json_req(:get, "/api/subscriptions?with_unread_count=true", nil, auth_header(token))
    assert conn.status == 200
    assert length(Jason.decode!(conn.resp_body)["subscriptions"]) == 3

    conn = json_req(:get, "/api/opml/export", nil, auth_header(token))
    assert conn.status == 200
    assert conn.resp_body =~ "xmlUrl="
  end

  test "force refresh requires subscription", %{user: user, token: token} do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/force_#{System.unique_integer([:positive])}.xml"
      })

    conn = json_req(:post, "/api/feeds/#{feed.id}/refresh", nil, auth_header(token))
    assert conn.status == 404

    {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

    previous = Application.get_env(:earss, :http_client)
    Application.put_env(:earss, :http_client, HTTPStub)

    on_exit(fn ->
      HTTPStub.clear()

      if previous do
        Application.put_env(:earss, :http_client, previous)
      else
        Application.delete_env(:earss, :http_client)
      end
    end)

    HTTPStub.put(fn _url, _opts -> {:ok, :not_modified} end)

    conn = json_req(:post, "/api/feeds/#{feed.id}/refresh", nil, auth_header(token))
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["result"] == "not_modified"
  end
end
