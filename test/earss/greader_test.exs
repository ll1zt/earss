defmodule Earss.GReaderTest do
  use Earss.ConnCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.GReader
  alias Earss.API.Router

  setup do
    username = "gr_#{System.unique_integer([:positive])}"
    password = "secret"
    {:ok, user} = Reader.create_user(username, password)
    %{user: user, username: username, password: password}
  end

  test "client_login and subscription list", %{user: user, username: username, password: password} do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/gr_#{System.unique_integer([:positive])}.xml",
        title: "GR"
      })

    {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

    assert {:ok, auth} = GReader.client_login(username, password)
    assert %{} = GReader.verify_auth(auth)

    list = GReader.subscription_list(user)
    assert length(list["subscriptions"]) == 1
    assert hd(list["subscriptions"])["url"] == feed.link
  end

  test "stream contents and edit-tag read", %{user: user, username: username, password: password} do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/gs_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, e1} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/1",
        guid: "1",
        title: "One",
        content: "Hi"
      })

    {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

    contents =
      GReader.stream_contents(user, "user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true
      )

    assert length(contents["items"]) == 1
    item_id = hd(contents["items"])["id"]

    :ok = GReader.edit_tag(user, [item_id], ["user/-/state/com.google/read"], [])
    assert Reader.get_entry_state(user, e1.id).is_read

    unread =
      GReader.stream_contents(user, "user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true
      )

    assert unread["items"] == []

    # HTTP ClientLogin
    body = URI.encode_query(%{"Email" => username, "Passwd" => password})

    conn =
      Plug.Test.conn(:post, "/api/greader.php/accounts/ClientLogin", body)
      |> Map.put(:host, "www.example.com")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])

    conn = Router.call(conn, Router.init([]))
    assert conn.status == 200
    assert conn.resp_body =~ "Auth="

    auth =
      conn.resp_body
      |> String.split("\n")
      |> Enum.find_value(fn
        "Auth=" <> t -> t
        _ -> nil
      end)

    conn =
      Plug.Test.conn(:get, "/api/greader.php/reader/api/0/subscription/list?output=json")
      |> Map.put(:host, "www.example.com")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("authorization", "GoogleLogin auth=#{auth}")

    conn = Router.call(conn, Router.init([]))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert length(body["subscriptions"]) == 1
  end

  test "bad login" do
    assert :error = GReader.client_login("nope", "x")
  end

  test "unread-count matches admin totals", %{user: user, username: username, password: password} do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/uc_#{System.unique_integer([:positive])}.xml"
      })

    for i <- 1..3 do
      {:ok, _} =
        Feeds.upsert_entry(feed, %{
          link: "https://example.com/#{i}",
          guid: "g#{i}",
          title: "T#{i}"
        })
    end

    {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

    payload = GReader.unread_count(user)
    assert payload["max"] == 1000

    reading =
      Enum.find(payload["unreadcounts"], &(&1["id"] == "user/-/state/com.google/reading-list"))

    assert reading["count"] == 3

    feed_row = Enum.find(payload["unreadcounts"], &String.starts_with?(&1["id"], "feed/"))
    assert feed_row["count"] == 3

    # HTTP endpoint
    {:ok, auth} = GReader.client_login(username, password)

    conn =
      Plug.Test.conn(:get, "/api/greader.php/reader/api/0/unread-count?output=json")
      |> Map.put(:host, "www.example.com")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("authorization", "GoogleLogin auth=#{auth}")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    rl = Enum.find(body["unreadcounts"], &(&1["id"] == "user/-/state/com.google/reading-list"))
    assert rl["count"] == 3
  end
end
