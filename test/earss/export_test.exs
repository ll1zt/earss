defmodule Earss.ExportTest do
  use Earss.DataCase

  alias Earss.Repo
  alias Earss.Export
  alias Earss.Feeds
  alias Earss.Feeds.Entry
  alias Earss.Reader

  defp unique_link do
    "https://example.com/feed_#{System.unique_integer([:positive])}.xml"
  end

  defp create_user do
    {:ok, user} = Reader.create_user("exp_#{System.unique_integer([:positive])}", "secret")
    user
  end

  defp seed_feed(attrs \\ []) do
    link = unique_link()

    {:ok, feed} =
      Feeds.create_feed(%{link: link, title: Keyword.get(attrs, :title, "Export Feed")})

    {:ok, %{entries: _}} =
      Feeds.upsert_entries(feed, [
        %{
          link: "#{link}/1",
          guid: "g1",
          title: "First",
          content: "<p>Hello <b>world</b></p>",
          published_at: ~U[2026-08-01 10:00:00Z]
        },
        %{
          link: "#{link}/2",
          guid: "g2",
          title: "Second",
          content: "Plain text body",
          published_at: ~U[2026-08-02 10:00:00Z]
        }
      ])

    feed
  end

  defp entries_of(feed) do
    Repo.all(from e in Entry, where: e.feed_id == ^feed.id, order_by: [asc: e.id])
  end

  # Ecto 3.13: Repo.stream must be consumed inside a Repo.transaction.
  defp rows_in_transaction(stream) do
    {:ok, rows} = Repo.transaction(fn -> Enum.to_list(stream) end)
    rows
  end

  describe "starred/2" do
    test "returns only starred entries, newest first, with feed info" do
      user = create_user()
      feed = seed_feed()
      {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      [_e1, e2] = entries_of(feed)

      {:ok, _} = Reader.set_star(user, e2.id, true)

      assert [row] = rows_in_transaction(Export.starred(user))
      assert row.entry_id == e2.id
      assert row.title == "Second"
      assert row.content == "Plain text body"
      assert row.feed_title == feed.title
      assert row.feed_link == feed.link
      assert row.site_url == feed.site_url
      assert row.feed_type == "rss"
      assert row.is_star == true
      assert row.is_read == false
    end

    test "includes starred entries from hidden subscriptions" do
      user = create_user()
      feed = seed_feed()
      {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      [_e1, e2] = entries_of(feed)
      {:ok, _} = Reader.set_star(user, e2.id, true)

      sub = Reader.get_subscription(user, feed.id)
      {:ok, _} = Reader.hide_subscription(sub)

      assert [row] = rows_in_transaction(Export.starred(user))
      assert row.entry_id == e2.id
    end

    test "returns empty when nothing starred" do
      user = create_user()
      feed = seed_feed()
      {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      assert rows_in_transaction(Export.starred(user)) == []
    end
  end

  describe "feed/3" do
    test "streams every entry of a subscribed feed, newest first" do
      user = create_user()
      feed = seed_feed()
      {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
      [e1, e2] = entries_of(feed)

      assert {:ok, returned_feed, stream} = Export.feed(user, feed.id)
      assert returned_feed.id == feed.id

      rows = rows_in_transaction(stream)
      assert [row1, row2] = rows
      assert row1.entry_id == e2.id
      assert row2.entry_id == e1.id
      assert row1.is_read == false
      assert row1.feed_link == feed.link
    end

    test "rejects a feed the user is not subscribed to" do
      user = create_user()
      feed = seed_feed()

      assert Export.feed(user, feed.id) == {:error, :not_found}
      assert Export.feed(user, -1) == {:error, :not_found}
    end
  end

  describe "all/1" do
    test "streams every entry across feeds with state fields nil" do
      user = create_user()
      feed1 = seed_feed(title: "Feed One")
      feed2 = seed_feed(title: "Feed Two")
      {:ok, _} = Reader.subscribe(user, %{feed_id: feed1.id, refresh: false})

      rows = rows_in_transaction(Export.all())
      assert length(rows) == 4
      assert Enum.all?(rows, &(&1.is_star == nil))
      assert Enum.all?(rows, &(&1.is_read == nil))
      assert Enum.map(rows, & &1.feed_title) |> Enum.uniq() |> length() == 2
      _ = feed2
    end
  end

  describe "chunks/3" do
    defp row_map(title, content, extra \\ []) do
      Map.merge(
        %{
          feed_id: 1,
          feed_title: "Feed",
          feed_link: "https://example.com/feed.xml",
          site_url: "https://example.com",
          feed_type: "rss",
          entry_id: 1,
          link: "https://example.com/post",
          guid: "g",
          title: title,
          author: "Alice",
          summary: nil,
          content: content,
          published_at: ~U[2026-08-01 10:00:00Z],
          inserted_at: ~U[2026-08-01 10:00:00Z],
          is_read: false,
          is_star: true,
          read_at: nil
        },
        Map.new(extra)
      )
    end

    defp render(format, rows, opts \\ []) do
      Export.chunks(format, rows, opts)
      |> Enum.to_list()
      |> IO.iodata_to_binary()
    end

    test "json is a valid self-describing array" do
      body =
        render(:json, [row_map("One", "<p>hi</p>"), row_map("Two", nil)],
          scope: "starred",
          user: "alice"
        )

      decoded = Jason.decode!(body)
      assert decoded["scope"] == "starred"
      assert decoded["user"] == "alice"
      assert decoded["generated"]

      assert [e1, e2] = decoded["entries"]
      assert e1["title"] == "One"
      assert e1["content"] == "<p>hi</p>"
      assert e1["feed_title"] == "Feed"
      assert e1["published_at"] == "2026-08-01T10:00:00Z"
      assert e1["is_star"] == true
      assert e2["content"] == nil
    end

    test "json handles an empty stream" do
      decoded = Jason.decode!(render(:json, []))
      assert decoded["entries"] == []
    end

    test "markdown strips html to plain text" do
      body =
        render(:markdown, [row_map("One", "<p>Hello <b>world</b></p>")],
          scope: "starred",
          user: "alice"
        )

      assert body =~ "# Earss export"
      assert body =~ "## One"
      assert body =~ "Hello world"
      refute body =~ "<b>"
      refute body =~ "<p>"
      assert body =~ "- Scope: starred"
      assert body =~ "- User: alice"
      assert body =~ "- Link: https://example.com/post"
    end

    test "markdown falls back to summary and escapes block markers" do
      body =
        render(:markdown, [
          row_map("use `code` & more", nil, summary: "line one\n- item\n# heading\n1. first")
        ])

      assert body =~ "use \\`code\\`"
      assert body =~ "line one"
      assert body =~ "\\- item"
      assert body =~ "\\# heading"
      assert body =~ "\\1. first"
    end

    test "markdown feed scope header includes feed info" do
      body =
        render(:markdown, [row_map("One", nil)],
          scope: "feed",
          feed: %{title: "My Feed", link: "https://example.com/feed.xml"}
        )

      assert body =~ "- Feed: My Feed (https://example.com/feed.xml)"
      assert body =~ "## One"
    end
  end
end
