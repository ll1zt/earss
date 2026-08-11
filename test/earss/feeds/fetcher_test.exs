defmodule Earss.Feeds.FetcherTest do
  use Earss.DataCase

  alias Earss.Feeds
  alias Earss.Feeds.HTTPStub
  alias Earss.Repo
  alias Earss.Feeds.Entry

  setup do
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

    :ok
  end

  defp fixture(name) do
    Path.join([File.cwd!(), "test/fixtures/feeds", name]) |> File.read!()
  end

  test "refresh ingests RSS entries and updates feed metadata" do
    body = fixture("sample.rss.xml")

    HTTPStub.put(fn _url, _opts ->
      {:ok,
       %{status: 200, body: body, etag: "\"abc\"", last_modified: "Mon, 01 Jan 2024 00:00:00 GMT"}}
    end)

    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/feed.xml"})

    assert {:ok, %{upserted: 2, skipped: 0, feed: refreshed}} = Feeds.refresh(feed)
    assert refreshed.feed_type == "rss"
    assert refreshed.title == "Example RSS"
    assert refreshed.etag == "\"abc\""
    assert refreshed.error_count == 0
    assert refreshed.last_fetched_at
    assert refreshed.next_fetch_at
    assert refreshed.last_fetched_content_hash
    assert Repo.aggregate(from(e in Entry, where: e.feed_id == ^feed.id), :count) == 2
  end

  test "refresh returns not_modified on HTTP 304" do
    HTTPStub.put(fn _url, opts ->
      assert opts[:etag] == "\"abc\""
      {:ok, :not_modified}
    end)

    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/feed.xml",
        etag: "\"abc\"",
        unchanged_fetch_count: 0
      })

    assert {:ok, :not_modified} = Feeds.refresh(feed)
    feed = Feeds.get_feed(feed.id)
    assert feed.unchanged_fetch_count == 1
    assert feed.error_count == 0
  end

  test "refresh returns not_modified when content hash unchanged" do
    body = fixture("sample.json")
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    HTTPStub.put(fn _url, _opts ->
      {:ok, %{status: 200, body: body, etag: nil, last_modified: nil}}
    end)

    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/feed.json",
        last_fetched_content_hash: hash
      })

    assert {:ok, :not_modified} = Feeds.refresh(feed)
    assert Repo.aggregate(Entry, :count) == 0
  end

  test "refresh records http errors and backs off" do
    HTTPStub.put(fn _url, _opts -> {:error, {:http, 500}} end)

    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/down.xml", refresh_interval: 30})

    assert {:error, {:http, 500}} = Feeds.refresh(feed)
    feed = Feeds.get_feed(feed.id)
    assert feed.error_count == 1
    assert feed.last_error
    assert feed.next_fetch_at
  end

  test "refresh disables feed after five consecutive errors" do
    HTTPStub.put(fn _url, _opts -> {:error, {:http, :timeout}} end)

    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/bad.xml", error_count: 4})

    assert {:error, {:http, :timeout}} = Feeds.refresh(feed)
    feed = Feeds.get_feed(feed.id)
    assert feed.error_count == 5
    assert feed.is_active == false
  end

  test "refresh parses atom via fixture" do
    body = fixture("sample.atom.xml")

    HTTPStub.put(fn _url, _opts ->
      {:ok, %{status: 200, body: body, etag: nil, last_modified: nil}}
    end)

    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/atom.xml"})
    assert {:ok, %{upserted: 2, feed: refreshed}} = Feeds.refresh(feed)
    assert refreshed.feed_type == "atom"
    assert refreshed.title == "Example Atom"
  end

  describe "translation hook" do
    alias Earss.Feeds.EntryTranslation
    alias Earss.Enrichment.Registry
    alias Earss.Test.FakeTranslator

    setup do
      # "aaa_" sorts before any translator id other test files may register, so
      # Earss.Enrichment.enricher/0 (first by id) reliably picks this fake.
      id = "aaa_fetcher_#{System.unique_integer([:positive])}"
      assert :ok == Registry.register(%{id: id, module: FakeTranslator})
      on_exit(fn -> Registry.unregister(id) end)
      :ok
    end

    test "translates freshly ingested entries when the feed is configured" do
      body = fixture("sample.rss.xml")

      HTTPStub.put(fn _url, _opts ->
        {:ok, %{status: 200, body: body, etag: nil, last_modified: nil}}
      end)

      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/feed.xml", translate_to: "zh"})

      assert {:ok, %{upserted: 2, skipped: 0}} = Feeds.refresh(feed)

      count =
        from(t in EntryTranslation,
          join: e in Entry,
          on: e.id == t.entry_id,
          where: e.feed_id == ^feed.id
        )
        |> Repo.aggregate(:count)

      assert count == 2
    end

    test "skips translation when no language is configured" do
      body = fixture("sample.rss.xml")

      HTTPStub.put(fn _url, _opts ->
        {:ok, %{status: 200, body: body, etag: nil, last_modified: nil}}
      end)

      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/feed.xml"})

      assert {:ok, %{upserted: 2}} = Feeds.refresh(feed)
      assert Repo.aggregate(EntryTranslation, :count) == 0
    end

    test "refresh still succeeds when the translator errors" do
      body = fixture("sample.rss.xml")

      HTTPStub.put(fn _url, _opts ->
        {:ok, %{status: 200, body: body, etag: nil, last_modified: nil}}
      end)

      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/feed.xml", translate_to: "zh"})

      Process.put(:fake_behavior, :error)
      on_exit(fn -> Process.delete(:fake_behavior) end)

      assert {:ok, %{upserted: 2, feed: refreshed}} = Feeds.refresh(feed)
      assert refreshed.error_count == 0
      assert Repo.aggregate(EntryTranslation, :count) == 0
    end
  end
end

defmodule Earss.EnrichmentIntegrationTest do
  use Earss.DataCase

  alias Earss.Feeds
  alias Earss.Feeds.HTTPStub
  alias Earss.Reader
  alias Earss.GReader
  alias Earss.Test.FakeTranslator

  setup do
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

    id = "aaa_integration_#{System.unique_integer([:positive])}"
    assert :ok == Earss.Enrichment.Registry.register(%{id: id, module: FakeTranslator})
    on_exit(fn -> Earss.Enrichment.Registry.unregister(id) end)
    :ok
  end

  test "refresh → translate → GReader stream serves the translation" do
    body = File.read!(Path.join([File.cwd!(), "test/fixtures/feeds/sample.rss.xml"]))

    HTTPStub.put(fn _url, _opts ->
      {:ok, %{status: 200, body: body, etag: nil, last_modified: nil}}
    end)

    {:ok, user} = Reader.create_user("itr_#{System.unique_integer([:positive])}", "secret")

    {:ok, feed} =
      Feeds.create_feed(%{
        link: "https://example.com/itr_#{System.unique_integer([:positive])}.xml",
        translate_to: "zh"
      })

    {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

    assert {:ok, %{upserted: 2}} = Feeds.refresh(feed)

    contents =
      GReader.stream_contents(user, "user/-/state/com.google/reading-list",
        n: 10,
        exclude_read: true
      )

    assert length(contents["items"]) == 2
    item = hd(contents["items"])
    # FakeTranslator prefixes "[译]"; original entry title from the fixture
    assert item["title"] =~ "[译]"
  end
end
