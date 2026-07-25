defmodule Earss.Source.PluginFeedTest do
  use Earss.DataCase, async: false

  alias Earss.Feeds
  alias Earss.Reader
  alias Earss.SourceStub

  setup do
    assert :ok = SourceStub.ensure_registered()
    :ok
  end

  test "ensure_feed resolves earss://stub and stores plugin fields" do
    assert {:ok, feed} = Feeds.ensure_feed("earss://stub/ping/alpha")
    assert feed.link == "earss://stub/ping/alpha"
    assert feed.adapter_id == "stub"
    assert feed.source_kind == "plugin"
    assert feed.feed_type == "plugin"
    assert feed.title == "Stub alpha"

    # second call returns same row
    assert {:ok, feed2} = Feeds.ensure_feed("earss://stub/ping/alpha")
    assert feed2.id == feed.id
  end

  test "unknown earss adapter is rejected" do
    assert {:error, {:unknown_adapter, "nope"}} =
             Feeds.ensure_feed("earss://nope/x")
  end

  test "refresh via stub adapter upserts entries and cursor" do
    assert {:ok, feed} = Feeds.ensure_feed("earss://stub/ping/beta")
    assert {:ok, %{upserted: 1, feed: updated}} = Feeds.refresh(feed)

    assert updated.adapter_cursor == %{"n" => 1}
    assert updated.last_fetched_content_hash == "stub-beta-1"

    entries = Feeds.list_entries(updated)
    assert length(entries) == 1
    assert hd(entries).title == "Hello beta"
  end

  test "subscribe accepts earss:// link" do
    {:ok, user} = Reader.create_user("plugin_user_#{System.unique_integer([:positive])}", "secret")

    assert {:ok, sub} =
             Reader.subscribe(user, %{link: "earss://stub/ping/gamma", refresh: false})

    assert sub.feed.link == "earss://stub/ping/gamma"
    assert sub.feed.adapter_id == "stub"
  end
end
