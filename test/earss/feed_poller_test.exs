defmodule Earss.FeedPollerTest do
  use Earss.DataCase

  alias Earss.FeedPoller
  alias Earss.FeedScheduler
  alias Earss.Feeds
  alias Earss.Feeds.HTTPStub
  alias Earss.Reader.AnchorUser
  alias Earss.Reader.Subscription
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

  test "poller refreshes due subscribed feeds" do
    body = File.read!(Path.join([File.cwd!(), "test/fixtures/feeds/sample.rss.xml"]))

    HTTPStub.put(fn _url, _opts ->
      {:ok, %{status: 200, body: body, etag: nil, last_modified: nil}}
    end)

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, feed} =
      Feeds.create_feed(%{link: "https://example.com/poll.xml", next_fetch_at: past})

    %Subscription{}
    |> Subscription.changeset(%{user_id: AnchorUser.id(), feed_id: feed.id})
    |> Repo.insert!()

    # Allow the supervised poller (another process) to use the sandbox connection.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    start_supervised!({FeedPoller, interval_ms: 60_000, batch_size: 10, max_concurrency: 2})

    # Wait for initial delayed tick (1s) + refresh
    Process.sleep(2_500)

    assert Repo.aggregate(from(e in Entry, where: e.feed_id == ^feed.id), :count) >= 1
    refreshed = Feeds.get_feed(feed.id)
    assert refreshed.last_fetched_at
  end

  test "list_due_feeds is empty without subscription even if initialized" do
    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/alone.xml"})
    {:ok, feed} = FeedScheduler.initialize_next_fetch(feed)
    assert FeedScheduler.list_due_feeds(10) == []
    assert feed.next_fetch_at
  end
end
