defmodule Earss.GReaderTest do
  use Earss.ConnCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.GReader
  alias Earss.API.Router
  alias Earss.Repo

  test "client_login and subscription list" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/gr_#{System.unique_integer([:positive])}.xml",
        title: "GR"
      })

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    assert {:ok, auth} = GReader.client_login("earss", "test-password")
    assert %{} = GReader.verify_auth(auth)

    list = GReader.subscription_list()
    assert length(list["subscriptions"]) == 1
    assert hd(list["subscriptions"])["url"] == feed.link
  end

  test "stream contents and edit-tag read" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/gs_#{System.unique_integer([:positive])}.xml"
      })

    published = ~U[2020-06-15 12:00:00Z]

    {:ok, e1} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/1",
        guid: "1",
        title: "One",
        content: "Hi",
        published_at: published
      })

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    contents =
      GReader.stream_contents("user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true
      )

    assert length(contents["items"]) == 1
    item = hd(contents["items"])
    item_id = item["id"]
    pub_unix = DateTime.to_unix(published)
    assert item["published"] == pub_unix
    assert item["timestampUsec"] == "#{pub_unix}000000"
    # crawl time is ingest (inserted_at), not forced equal to published
    assert String.to_integer(item["crawlTimeMsec"]) >= pub_unix * 1000

    :ok = GReader.edit_tag([item_id], ["user/-/state/com.google/read"], [])
    assert Reader.get_entry_state(e1.id).is_read

    unread =
      GReader.stream_contents("user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true
      )

    assert unread["items"] == []

    # HTTP ClientLogin
    body = URI.encode_query(%{"Email" => "earss", "Passwd" => "test-password"})

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
    assert :error = GReader.client_login("nope", "wrong-pass")
  end

  test "stream item ids use decimal form for NetNewsWire" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/hex_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, e1} =
      Feeds.upsert_entry(feed, %{link: "https://example.com/h1", guid: "h1", title: "H1"})

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    ids =
      GReader.stream_item_ids("user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true
      )

    ref = hd(ids["itemRefs"])
    assert ref["id"] == Integer.to_string(e1.id)
    refute Map.has_key?(ids, "continuation")
  end

  test "parse_item_id treats /item/<hex> as hex (NNW contents fetch)" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/parse_#{System.unique_integer([:positive])}.xml",
        title: "ParseFeed"
      })

    # Use a known id range: create until we can assert hex/dec ambiguity if possible.
    # Entry id 51 is hex "33" — critical NNW case. We just need any id and encode as hex.
    {:ok, e1} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/p1",
        guid: "p1",
        title: "Parse Me",
        content: "body"
      })

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    hex = Integer.to_string(e1.id, 16)
    # Unpadded hex like NNW sends (String(idValue, radix: 16))
    atom_id = "tag:google.com,2005:reader/item/#{hex}"

    assert GReader.parse_item_id(atom_id) == e1.id

    # When hex string is pure digits that differ from decimal, /item/ path must use hex.
    # Force-check with synthetic id-like hex "33" -> 51, not 33.
    assert GReader.parse_item_id("tag:google.com,2005:reader/item/33") == 0x33
    assert GReader.parse_item_id("tag:google.com,2005:reader/item/0000000000000033") == 0x33

    # Bare decimal itemRefs stay decimal
    assert GReader.parse_item_id(Integer.to_string(e1.id)) == e1.id

    contents = GReader.items_contents([atom_id])
    assert length(contents["items"]) == 1
    item = hd(contents["items"])
    assert item["title"] == "Parse Me"
    assert item["origin"]["streamId"] == "feed/#{feed.id}"
    assert is_binary(item["crawlTimeMsec"])

    # subscription list uses numeric feed id
    list = GReader.subscription_list()
    assert hd(list["subscriptions"])["id"] == "feed/#{feed.id}"

    # unread-count feed row uses numeric id
    uc = GReader.unread_count()
    assert Enum.any?(uc["unreadcounts"], &(&1["id"] == "feed/#{feed.id}"))
  end

  test "ot near now does not hide items; unread ignores ot" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/ot_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, _} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/ot1",
        guid: "ot1",
        title: "OT",
        published_at: ~U[2023-01-01 00:00:00Z]
      })

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    now = System.system_time(:second)

    ids =
      GReader.stream_item_ids("user/-/state/com.google/reading-list",
        n: 100,
        ot: now + 60
      )

    assert length(ids["itemRefs"]) == 1

    ids2 =
      GReader.stream_item_ids("user/-/state/com.google/reading-list",
        n: 100,
        ot: now,
        exclude_read: true
      )

    assert length(ids2["itemRefs"]) == 1
  end

  test "stream/items/contents keeps all repeated i= form fields (NNW)" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/multi_#{System.unique_integer([:positive])}.xml",
        title: "Multi"
      })

    entries =
      for i <- 1..5 do
        {:ok, e} =
          Feeds.upsert_entry(feed, %{
            link: "https://example.com/m#{i}",
            guid: "m#{i}",
            title: "M#{i}",
            content: "c#{i}"
          })

        e
      end

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    {:ok, auth} = GReader.client_login("earss", "test-password")
    token = GReader.issue_edit_token()

    hex_part =
      entries
      |> Enum.map(fn e ->
        "i=" <>
          URI.encode_www_form("tag:google.com,2005:reader/item/#{Integer.to_string(e.id, 16)}")
      end)
      |> Enum.join("&")

    body = "T=#{URI.encode_www_form(token)}&output=json&#{hex_part}"

    conn =
      Plug.Test.conn(:post, "/api/greader.php/reader/api/0/stream/items/contents", body)
      |> Map.put(:host, "www.example.com")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Conn.put_req_header("authorization", "GoogleLogin auth=#{auth}")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    payload = Jason.decode!(conn.resp_body)
    assert length(payload["items"]) == 5
    # NNW ReaderAPIEntryWrapper requires top-level `updated`
    assert is_integer(payload["updated"])
    assert is_binary(payload["id"])

    titles = payload["items"] |> Enum.map(& &1["title"]) |> Enum.sort()
    assert titles == ["M1", "M2", "M3", "M4", "M5"]

    assert Enum.all?(payload["items"], &(&1["origin"]["streamId"] == "feed/#{feed.id}"))
  end

  test "short stream ids expand (reading-list / starred)" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/short_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, e1} =
      Feeds.upsert_entry(feed, %{link: "https://example.com/s1", guid: "s1", title: "S1"})

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
    :ok = GReader.edit_tag([e1.id], ["user/-/state/com.google/starred"], [])

    assert GReader.normalize_stream_id("reading-list") ==
             "user/-/state/com.google/reading-list"

    assert GReader.normalize_stream_id("starred") == "user/-/state/com.google/starred"

    rl = GReader.stream_contents("reading-list", n: 10)
    assert length(rl["items"]) == 1
    assert rl["id"] == "user/-/state/com.google/reading-list" or rl["title"] == "Reading list"

    starred = GReader.stream_contents("starred", n: 10)
    assert length(starred["items"]) == 1
  end

  test "subscription/edit subscribe and unsubscribe" do
    link = "https://example.com/subedit_#{System.unique_integer([:positive])}.xml"
    {:ok, feed} = Feeds.create_feed(%{link: link, title: "SubEdit"})

    assert :ok =
             GReader.subscription_edit(%{
               "ac" => "subscribe",
               "s" => "feed/#{link}",
               "t" => "My Title",
               "a" => "user/-/label/Work"
             })

    sub = Reader.get_subscription(feed.id)
    assert sub
    assert sub.custom_title == "My Title"
    assert Repo.preload(sub, :category).category.name == "Work"

    list = GReader.subscription_list()
    assert Enum.any?(list["subscriptions"], &(&1["id"] == "feed/#{feed.id}"))

    assert :ok =
             GReader.subscription_edit(%{
               "ac" => "unsubscribe",
               "s" => "feed/#{feed.id}"
             })

    refute Reader.get_subscription(feed.id)

    # HTTP path with edit token
    {:ok, feed2} =
      Feeds.create_feed(%{
        link: "https://example.com/subedit2_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, auth} = GReader.client_login("earss", "test-password")
    token = GReader.issue_edit_token()

    body =
      URI.encode_query(%{
        "T" => token,
        "ac" => "subscribe",
        "s" => "feed/#{feed2.link}",
        "t" => "HTTP Sub"
      })

    conn =
      Plug.Test.conn(:post, "/api/greader.php/reader/api/0/subscription/edit", body)
      |> Map.put(:host, "www.example.com")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Conn.put_req_header("authorization", "GoogleLogin auth=#{auth}")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert conn.resp_body == "OK"
    assert Reader.get_subscription(feed2.id)

    # missing T rejected
    body2 = URI.encode_query(%{"ac" => "unsubscribe", "s" => "feed/#{feed2.id}"})

    conn2 =
      Plug.Test.conn(:post, "/api/greader.php/reader/api/0/subscription/edit", body2)
      |> Map.put(:host, "www.example.com")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Conn.put_req_header("authorization", "GoogleLogin auth=#{auth}")
      |> Router.call(Router.init([]))

    assert conn2.status == 401
  end

  test "edit-tag HTTP requires T token" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/tok_#{System.unique_integer([:positive])}.xml"
      })

    {:ok, e1} =
      Feeds.upsert_entry(feed, %{link: "https://example.com/tok1", guid: "tok1", title: "Tok"})

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
    {:ok, auth} = GReader.client_login("earss", "test-password")
    token = GReader.issue_edit_token()

    body =
      URI.encode_query(%{
        "T" => token,
        "i" => Integer.to_string(e1.id),
        "a" => "user/-/state/com.google/read"
      })

    conn =
      Plug.Test.conn(:post, "/api/greader.php/reader/api/0/edit-tag", body)
      |> Map.put(:host, "www.example.com")
      |> Map.put(:secret_key_base, Application.fetch_env!(:earss, :api)[:secret_key_base])
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Conn.put_req_header("authorization", "GoogleLogin auth=#{auth}")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert Reader.get_entry_state(e1.id).is_read
  end

  test "unread-count matches admin totals" do
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

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    payload = GReader.unread_count()
    assert payload["max"] == 1000

    reading =
      Enum.find(payload["unreadcounts"], &(&1["id"] == "user/-/state/com.google/reading-list"))

    assert reading["count"] == 3

    feed_row = Enum.find(payload["unreadcounts"], &String.starts_with?(&1["id"], "feed/"))
    assert feed_row["count"] == 3

    # HTTP endpoint
    {:ok, auth} = GReader.client_login("earss", "test-password")

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

defmodule Earss.GReaderTranslationTest do
  use Earss.ConnCase

  alias Earss.Reader
  alias Earss.Feeds
  alias Earss.GReader
  alias Earss.Repo
  alias Earss.Feeds.EntryTranslation

  defp seed_translated_feed!(sub_attrs \\ []) do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/grt_#{System.unique_integer([:positive])}.xml",
        translate_to: "zh"
      })

    {:ok, entry} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/grt/1",
        guid: "grt-1",
        title: "Original title",
        content: "<p>Original body</p>"
      })

    {:ok, sub} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    sub =
      if sub_attrs != [] do
        {:ok, sub} = Earss.Reader.Subscriptions.update_subscription(sub, Map.new(sub_attrs))
        sub
      else
        sub
      end

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

    feed
  end

  test "stream contents substitutes feed-level translation" do
    _feed = seed_translated_feed!()

    contents =
      GReader.stream_contents("user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true
      )

    item = hd(contents["items"])
    assert item["title"] == "译题"
    assert item["summary"]["content"] == "<p>译正文</p>"
  end

  test "subscription override appends the original after the translation" do
    _feed = seed_translated_feed!(translate_to: "zh", original_layout: "section")

    contents =
      GReader.stream_contents("user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true
      )

    item = hd(contents["items"])
    assert item["title"] == "译题"

    assert item["summary"]["content"] ==
             "<p>译正文</p><hr class=\"earss-original\">" <>
               ~s(<div class="earss-original-section"><p>Original body</p></div>)
  end

  test "original: true returns the original text (escape hatch)" do
    _feed = seed_translated_feed!(translate_to: "zh")

    contents =
      GReader.stream_contents("user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true,
        original: true
      )

    item = hd(contents["items"])
    assert item["title"] == "Original title"
    assert item["summary"]["content"] == "<p>Original body</p>"
  end

  test "feed-level section layout appends a wrapped original in stream contents" do
    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/grt_#{System.unique_integer([:positive])}.xml",
        translate_to: "zh",
        original_layout: "section"
      })

    {:ok, entry} =
      Feeds.upsert_entry(feed, %{
        link: "https://example.com/grt/2",
        guid: "grt-2",
        title: "Original title",
        content: "<p>Original body</p>"
      })

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

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

    contents =
      GReader.stream_contents("user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true
      )

    item = hd(contents["items"])
    assert item["title"] == "译题"

    assert item["summary"]["content"] ==
             "<p>译正文</p><hr class=\"earss-original\">" <>
               ~s(<div class="earss-original-section"><p>Original body</p></div>)
  end
end
