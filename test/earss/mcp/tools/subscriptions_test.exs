defmodule Earss.MCP.Tools.SubscriptionsTest do
  @moduledoc """
  Tests for the subscription management tools.

  The important properties are the ones that would be expensive to get wrong
  in production: subscribing fetches immediately (and is therefore
  SSRF-gated, since the URL is agent-supplied), unsubscribing drops read
  state, and updates only touch the fields passed. These mirror what the
  admin UI already guarantees, because the tools go through the same
  `Earss.Reader` facade.
  """

  use Earss.DataCase, async: false

  alias Earss.Feeds
  alias Earss.Feeds.HTTPStub
  alias Earss.MCP.Tools.Subscriptions
  alias Earss.Reader
  alias Earss.Repo

  setup do
    previous_client = Application.get_env(:earss, :http_client)
    Application.put_env(:earss, :http_client, HTTPStub)

    HTTPStub.ensure_table!()
    HTTPStub.clear()

    on_exit(fn ->
      HTTPStub.clear()

      if previous_client do
        Application.put_env(:earss, :http_client, previous_client)
      else
        Application.delete_env(:earss, :http_client)
      end
    end)

    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/mcp-sub.xml", title: "Sub Feed"})
    %{feed: feed}
  end

  defp tool(name), do: Enum.find(Subscriptions.tools(), &(&1.name == name))

  defp call(name, args \\ %{}), do: tool(name).handler.(args)

  describe "feed_subscribe/1" do
    test "subscribes to an existing feed by id", %{feed: feed} do
      assert {:ok, result} = call("feed_subscribe", %{"feed_id" => feed.id})
      assert result.subscription.feed_id == feed.id
    end

    test "subscribing by link fetches through the stub (SSRF-gated)" do
      # The stub stands in for the HTTP client; if the tool fetched the URL
      # it would be visible here.
      HTTPStub.put(fn _url, _opts ->
        {:ok, %{status: 200, body: "<rss/>", etag: nil, last_modified: nil}}
      end)

      assert {:ok, result} =
               call("feed_subscribe", %{
                 "link" => "https://example.com/agent-link.xml",
                 "refresh" => false
               })

      assert result.subscription.feed_link == "https://example.com/agent-link.xml"
    end

    test "errors on a missing feed reference" do
      assert {:error, msg} = call("feed_subscribe", %{})
      assert msg =~ "link or feed_id"
    end

    test "refuses an internal URL (SSRF gate)" do
      # An agent-supplied URL is untrusted input like any other; the link
      # must not be fetchable into the private network. ensure_feed resolves
      # through the SSRF blocklist, so subscribing to loopback/metadata must
      # fail rather than open a socket.
      assert {:error, msg} =
               call("feed_subscribe", %{"link" => "http://169.254.169.254/latest/meta-data/"})

      assert is_binary(msg)
    end

    test "is mutating" do
      assert tool("feed_subscribe").mutating == true
    end
  end

  describe "feed_unsubscribe/1" do
    test "removes the subscription and its read state", %{feed: feed} do
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

      {:ok, %{entries: [entry]}} =
        Feeds.upsert_entries(feed, [%{guid: "u1", link: "https://e.com/u1", title: "U"}])

      {:ok, _} = Reader.mark_read(entry.id)

      assert {:ok, result} = call("feed_unsubscribe", %{"feed_id" => feed.id})
      assert result.unsubscribed == true

      assert is_nil(Reader.get_subscription(feed.id))
      assert is_nil(Repo.get_by(Earss.Reader.EntryState, entry_id: entry.id))
    end

    test "without confirm it reports impact and touches nothing", %{feed: feed} do
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

      {:ok, result, _state} =
        Earss.MCP.Handler.handle_call_tool("feed_unsubscribe", %{"feed_id" => feed.id}, %{})

      report = result["structuredContent"]

      assert report.executed == false
      assert report.requires_confirmation == true
      assert report.feed_id == feed.id
      assert report.affected == :subscription

      # Nothing was touched.
      assert Reader.get_subscription(feed.id)
    end

    test "with confirm it actually unsubscribes", %{feed: feed} do
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

      {:ok, result, _state} =
        Earss.MCP.Handler.handle_call_tool(
          "feed_unsubscribe",
          %{"feed_id" => feed.id, "confirm" => true},
          %{}
        )

      report = result["structuredContent"]
      assert report.unsubscribed == true
      assert is_nil(Reader.get_subscription(feed.id))
    end

    test "errors when there is no subscription" do
      assert {:error, msg} = call("feed_unsubscribe", %{"feed_id" => 999_999})
      assert msg =~ "no subscription"
    end

    test "is mutating and destructive" do
      assert tool("feed_unsubscribe").mutating == true
      assert tool("feed_unsubscribe").destructive == true
    end
  end

  describe "feed_update/1" do
    test "updates only the passed fields", %{feed: feed} do
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

      assert {:ok, result} =
               call("feed_update", %{"feed_id" => feed.id, "custom_title" => "Renamed"})

      assert result.subscription.custom_title == "Renamed"
      # is_hidden was not passed, so it must be untouched.
      assert result.subscription.is_hidden == false
    end

    test "errors when nothing is passed to update", %{feed: feed} do
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

      assert {:error, msg} = call("feed_update", %{"feed_id" => feed.id})
      assert msg =~ "nothing to update"
    end

    test "errors when the subscription is missing" do
      assert {:error, msg} = call("feed_update", %{"feed_id" => 999_999})
      assert msg =~ "no subscription"
    end
  end

  describe "feed_refresh/1" do
    test "reports upserted and skipped through the stub", %{feed: feed} do
      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

      # Feeds.refresh fetches the feed's own link through the HTTP client;
      # the stub answers any URL with a valid RSS document.
      HTTPStub.put(fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: """
           <rss version="2.0"><channel><title>t</title><item>
             <guid>r1</guid><link>https://e.com/r1</link><title>Refreshed</title>
           </item></channel></rss>
           """,
           etag: nil,
           last_modified: nil
         }}
      end)

      assert {:ok, result} = call("feed_refresh", %{"feed_id" => feed.id})
      assert result.upserted == 1
      assert result.skipped == 0
    end

    test "errors on a missing feed" do
      assert {:error, msg} = call("feed_refresh", %{"feed_id" => 999_999})
      assert msg =~ "not found"
    end
  end
end
