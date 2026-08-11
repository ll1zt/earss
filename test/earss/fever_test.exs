defmodule Earss.FeverTest do
  use Earss.ConnCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.Fever

  setup do
    username = "fever_#{System.unique_integer([:positive])}"
    password = "secret"
    {:ok, user} = Reader.create_user(username, password)
    api_key = Reader.fever_api_key(username, password)
    assert user.fever_api_key == api_key
    %{user: user, api_key: api_key, username: username, password: password}
  end

  test "auth fails with bad key" do
    resp = Fever.handle(%{"api_key" => "deadbeef", "api" => ""})
    assert resp["auth"] == 0
  end

  test "auth succeeds and returns groups/feeds", %{user: user, api_key: api_key} do
    {:ok, cat} = Reader.create_category(user, %{name: "Blogs"})

    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/fv_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, _} =
      Reader.subscribe(user, %{
        feed_id: feed.id,
        category_id: cat.id,
        refresh: false
      })

    resp =
      Fever.handle(%{
        "api_key" => api_key,
        "api" => "",
        "groups" => "",
        "feeds" => ""
      })

    assert resp["auth"] == 1
    assert resp["api_version"] == 3
    assert Enum.any?(resp["groups"], &(&1["title"] == "Blogs"))
    assert Enum.any?(resp["feeds"], &(&1["id"] == feed.id))
    assert is_list(resp["feeds_groups"])
  end

  test "feeds alone still returns feeds_groups", %{user: user, api_key: api_key} do
    {:ok, cat} = Reader.create_category(user, %{name: "News"})

    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/fg_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, _} =
      Reader.subscribe(user, %{feed_id: feed.id, category_id: cat.id, refresh: false})

    resp = Fever.handle(%{"api_key" => api_key, "api" => "", "feeds" => ""})
    assert resp["auth"] == 1
    refute Map.has_key?(resp, "groups")
    assert Enum.any?(resp["feeds"], &(&1["id"] == feed.id))

    fg = Enum.find(resp["feeds_groups"], &(&1["group_id"] == cat.id))
    assert fg
    assert to_string(feed.id) in String.split(fg["feed_ids"], ",", trim: true)
  end

  test "total_items is full visible count not page size", %{user: user, api_key: api_key} do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/ti_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, e1} =
      Feeds.upsert_entry(feed, %{link: "https://example.com/ti1", guid: "ti1", title: "T1"})

    for i <- 2..3 do
      {:ok, _} =
        Feeds.upsert_entry(feed, %{
          link: "https://example.com/ti#{i}",
          guid: "ti#{i}",
          title: "T#{i}"
        })
    end

    {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

    resp =
      Fever.handle(%{
        "api_key" => api_key,
        "items" => "",
        "with_ids" => to_string(e1.id)
      })

    assert length(resp["items"]) == 1
    assert resp["total_items"] == 3
  end

  test "items unread saved and mark item", %{user: user, api_key: api_key} do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/fi_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, e1} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/a",
        guid: "a",
        title: "A",
        content: "<p>Hi</p>"
      })

    {:ok, e2} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/b",
        guid: "b",
        title: "B"
      })

    {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

    resp =
      Fever.handle(%{
        "api_key" => api_key,
        "unread_item_ids" => "",
        "items" => "",
        "since_id" => "0"
      })

    assert resp["auth"] == 1
    unread = String.split(resp["unread_item_ids"], ",", trim: true)
    assert to_string(e1.id) in unread
    assert to_string(e2.id) in unread
    assert length(resp["items"]) == 2

    # mark read
    Fever.handle(%{
      "api_key" => api_key,
      "mark" => "item",
      "as" => "read",
      "id" => to_string(e1.id)
    })

    resp2 = Fever.handle(%{"api_key" => api_key, "unread_item_ids" => ""})
    unread2 = String.split(resp2["unread_item_ids"], ",", trim: true)
    refute to_string(e1.id) in unread2
    assert to_string(e2.id) in unread2

    # star
    Fever.handle(%{
      "api_key" => api_key,
      "mark" => "item",
      "as" => "saved",
      "id" => to_string(e2.id)
    })

    resp3 = Fever.handle(%{"api_key" => api_key, "saved_item_ids" => ""})
    assert to_string(e2.id) in String.split(resp3["saved_item_ids"], ",", trim: true)
  end

  test "HTTP plug fever endpoint", %{api_key: api_key} do
    conn =
      Plug.Test.conn(:post, "/fever/?api", "api_key=#{api_key}&groups")
      |> Map.put(:host, "www.example.com")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")

    conn = Earss.API.Router.call(conn, Earss.API.Router.init([]))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["auth"] == 1
    assert is_list(body["groups"])
  end

  test "set_fever_password changes api key", %{user: user, username: username} do
    assert {:ok, user} = Reader.set_fever_password(user, "other-secret")
    assert user.fever_api_key == Reader.fever_api_key(username, "other-secret")

    assert Fever.handle(%{"api_key" => user.fever_api_key})["auth"] == 1
  end
end

defmodule Earss.FeverTranslationTest do
  use Earss.ConnCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.Fever
  alias Earss.Repo
  alias Earss.Feeds.EntryTranslation

  setup do
    username = "fevertr_#{System.unique_integer([:positive])}"
    password = "secret"
    {:ok, user} = Reader.create_user(username, password)
    api_key = Reader.fever_api_key(username, password)
    %{user: user, api_key: api_key}
  end

  test "items reflect feed-level translation", %{user: user, api_key: api_key} do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/fevertr_#{System.unique_integer([:positive])}.xml",
        translate_to: "zh"
      })

    {:ok, entry} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/fevertr/1",
        guid: "fevertr-1",
        title: "Original title",
        content: "<p>Original body</p>"
      })

    {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

    %EntryTranslation{}
    |> EntryTranslation.changeset(%{
      entry_id: entry.id,
      lang: "zh",
      title: "译题",
      content: "<p>译正文</p>",
      original_hash: entry.content_hash,
      model: "test",
      translated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    resp = Fever.handle(%{"api_key" => api_key, "api" => "", "items" => ""})

    item = Enum.find(resp["items"], &(&1["id"] == entry.id))
    assert item["title"] == "译题"
    assert item["html"] == "<p>译正文</p>"
  end
end
