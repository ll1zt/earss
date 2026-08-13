defmodule Earss.FeedSchedulerTest do
  use Earss.DataCase

  alias Earss.FeedScheduler
  alias Earss.Feeds
  alias Earss.Feeds.Feed
  alias Earss.Reader.Subscription
  alias Earss.Repo

  defp feed_struct(attrs) do
    defaults = %{
      link: "https://example.com/f.xml",
      refresh_interval: 30,
      min_refresh_interval: 15,
      max_refresh_interval: 10080,
      error_count: 0
    }

    struct(Feed, Map.merge(defaults, attrs))
  end

  describe "clamp_interval/2" do
    test "clamps to min and max" do
      feed = feed_struct(%{min_refresh_interval: 15, max_refresh_interval: 60})
      assert FeedScheduler.clamp_interval(feed, 10) == 15
      assert FeedScheduler.clamp_interval(feed, 100) == 60
      assert FeedScheduler.clamp_interval(feed, 30) == 30
    end
  end

  describe "effective_interval/2" do
    test "uses min of refresh and custom intervals" do
      feed =
        feed_struct(%{refresh_interval: 30, min_refresh_interval: 10, max_refresh_interval: 120})

      assert FeedScheduler.effective_interval(feed, [20, 45]) == 20
      assert FeedScheduler.effective_interval(feed, []) == 30
    end

    test "loads customs from subscriptions" do
      {:ok, feed} =
        Feeds.create_feed(%{
          link: "https://example.com/sched.xml",
          refresh_interval: 60,
          min_refresh_interval: 10,
          max_refresh_interval: 120
        })

      # the single operator has one subscription per feed (the former
      # two-users-one-feed variant is no longer expressible — see
      # docs/single_user.md)
      %Subscription{}
      |> Subscription.changeset(%{
        feed_id: feed.id,
        custom_refresh_interval: 15
      })
      |> Repo.insert!()

      assert FeedScheduler.effective_interval(feed) == 15
    end
  end

  describe "next_refresh_interval/3" do
    test "shortens on new content and lengthens on no content" do
      feed =
        feed_struct(%{refresh_interval: 30, min_refresh_interval: 15, max_refresh_interval: 120})

      assert FeedScheduler.next_refresh_interval(feed, :success_new_content, custom_intervals: []) ==
               27

      assert FeedScheduler.next_refresh_interval(feed, :success_no_content, custom_intervals: []) ==
               36
    end

    test "respects min when shortening" do
      feed =
        feed_struct(%{refresh_interval: 16, min_refresh_interval: 15, max_refresh_interval: 120})

      assert FeedScheduler.next_refresh_interval(feed, :success_new_content, custom_intervals: []) ==
               15
    end
  end

  describe "schedule_attrs/3" do
    test "error increments count and eventually disables" do
      feed = feed_struct(%{error_count: 4, refresh_interval: 30})
      now = ~U[2026-01-01 00:00:00Z]

      attrs =
        FeedScheduler.schedule_attrs(feed, :error,
          now: now,
          custom_intervals: [],
          error_count: 4
        )

      assert attrs.error_count == 5
      assert attrs.is_active == false
      assert attrs.next_fetch_at
    end

    test "success clears error_count and adapts interval" do
      feed = feed_struct(%{error_count: 2, refresh_interval: 30})
      now = ~U[2026-01-01 00:00:00Z]

      attrs =
        FeedScheduler.schedule_attrs(feed, :success_new_content, now: now, custom_intervals: [])

      assert attrs.error_count == 0
      assert attrs.refresh_interval == 27
      assert attrs.next_fetch_at == DateTime.add(now, 27 * 60, :second)
    end
  end

  describe "list_due_feeds/2" do
    test "returns only active subscribed due feeds" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      past = DateTime.add(now, -3600, :second)
      future = DateTime.add(now, 3600, :second)

      {:ok, due} =
        Feeds.create_feed(%{link: "https://example.com/due.xml", next_fetch_at: past})

      {:ok, future_feed} =
        Feeds.create_feed(%{link: "https://example.com/future.xml", next_fetch_at: future})

      {:ok, unsub} =
        Feeds.create_feed(%{
          link: "https://example.com/unsub.xml",
          next_fetch_at: past,
          last_unsubscribed_at: past
        })

      {:ok, inactive} =
        Feeds.create_feed(%{
          link: "https://example.com/off.xml",
          next_fetch_at: past,
          is_active: false
        })

      {:ok, no_sub} =
        Feeds.create_feed(%{link: "https://example.com/nosub.xml", next_fetch_at: past})

      for f <- [due, future_feed, unsub, inactive] do
        %Subscription{}
        |> Subscription.changeset(%{feed_id: f.id})
        |> Repo.insert!()
      end

      # no_sub intentionally has no subscription
      _ = no_sub

      ids = FeedScheduler.list_due_feeds(50, now) |> Enum.map(& &1.id)
      assert due.id in ids
      refute future_feed.id in ids
      refute unsub.id in ids
      refute inactive.id in ids
      refute no_sub.id in ids
    end

    test "includes feeds with nil next_fetch_at when subscribed" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/nilnext.xml"})
      assert is_nil(feed.next_fetch_at)

      %Subscription{}
      |> Subscription.changeset(%{feed_id: feed.id})
      |> Repo.insert!()

      ids = FeedScheduler.list_due_feeds(50, now) |> Enum.map(& &1.id)
      assert feed.id in ids
    end
  end

  describe "initialize_next_fetch/1" do
    test "sets next_fetch_at" do
      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/init.xml"})
      assert is_nil(feed.next_fetch_at)
      assert {:ok, feed} = FeedScheduler.initialize_next_fetch(feed)
      assert feed.next_fetch_at
    end
  end
end
