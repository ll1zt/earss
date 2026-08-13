defmodule Earss.SchemaContractTest do
  use Earss.DataCase

  alias Earss.Repo
  alias Earss.Feeds.Feed
  alias Earss.Feeds.Entry
  alias Earss.Reader.Category
  alias Earss.Reader.Subscription
  alias Earss.Reader.EntryState

  defp insert_feed!(attrs \\ %{}) do
    defaults = %{
      link: "https://example.com/feed_#{System.unique_integer([:positive])}.xml",
      title: "Example"
    }

    %Feed{}
    |> Feed.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_entry!(feed, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      feed_id: feed.id,
      link: "https://example.com/posts/#{n}",
      guid: "guid-#{n}",
      title: "Post #{n}"
    }

    %Entry{}
    |> Entry.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  test "feed link is unique" do
    insert_feed!(%{link: "https://example.com/same.xml"})

    assert {:error, changeset} =
             %Feed{}
             |> Feed.changeset(%{link: "https://example.com/same.xml"})
             |> Repo.insert()

    assert %{link: _} = errors_on(changeset)
  end

  test "feed defaults and type check" do
    feed = insert_feed!()
    assert feed.refresh_interval == 30
    assert feed.min_refresh_interval == 15
    assert feed.max_refresh_interval == 10_080
    assert feed.is_active == true

    assert {:error, changeset} =
             %Feed{}
             |> Feed.changeset(%{link: "https://x.test/a.xml", feed_type: "nope"})
             |> Repo.insert()

    assert "is invalid" in errors_on(changeset).feed_type
  end

  test "entry (feed_id, guid) is unique" do
    feed = insert_feed!()
    insert_entry!(feed, %{guid: "g1", link: "https://example.com/1"})

    assert {:error, changeset} =
             %Entry{}
             |> Entry.changeset(%{
               feed_id: feed.id,
               guid: "g1",
               link: "https://example.com/2"
             })
             |> Repo.insert()

    assert errors_on(changeset) != %{}
  end

  test "subscription feed_id is unique (single operator)" do
    feed = insert_feed!()

    assert {:ok, _} =
             %Subscription{}
             |> Subscription.changeset(%{feed_id: feed.id})
             |> Repo.insert()

    assert {:error, _} =
             %Subscription{}
             |> Subscription.changeset(%{feed_id: feed.id})
             |> Repo.insert()
  end

  test "category name is unique (single operator)" do
    assert {:ok, _} =
             %Category{}
             |> Category.changeset(%{name: "News"})
             |> Repo.insert()

    assert {:error, _} =
             %Category{}
             |> Category.changeset(%{name: "News"})
             |> Repo.insert()
  end

  test "deleting category nilifies subscription.category_id" do
    feed = insert_feed!()

    category =
      %Category{}
      |> Category.changeset(%{name: "Tech"})
      |> Repo.insert!()

    sub =
      %Subscription{}
      |> Subscription.changeset(%{
        feed_id: feed.id,
        category_id: category.id
      })
      |> Repo.insert!()

    Repo.delete!(category)
    sub = Repo.get!(Subscription, sub.id)
    assert is_nil(sub.category_id)
  end

  test "deleting feed cascades entries, states, subscriptions" do
    feed = insert_feed!()
    entry = insert_entry!(feed)

    %Subscription{}
    |> Subscription.changeset(%{feed_id: feed.id})
    |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %EntryState{}
    |> EntryState.changeset(%{
      entry_id: entry.id,
      is_read: true,
      read_at: now
    })
    |> Repo.insert!()

    Repo.delete!(feed)

    assert Repo.get(Entry, entry.id) == nil
    assert Repo.aggregate(Subscription, :count) == 0
    assert Repo.aggregate(EntryState, :count) == 0
  end

  test "entry_state read_at consistency via changeset" do
    feed = insert_feed!()
    entry = insert_entry!(feed)

    assert {:ok, state} =
             %EntryState{}
             |> EntryState.changeset(%{
               entry_id: entry.id,
               is_read: true
             })
             |> Repo.insert()

    assert state.is_read
    assert state.read_at

    assert {:ok, state} =
             state
             |> EntryState.changeset(%{is_read: false})
             |> Repo.update()

    assert state.is_read == false
    assert is_nil(state.read_at)
  end

  test "entry_state rejects read without read_at at DB level" do
    feed = insert_feed!()
    entry = insert_entry!(feed)

    assert_raise Postgrex.Error, fn ->
      Repo.insert_all("entry_states", [
        %{
          entry_id: entry.id,
          is_read: true,
          is_star: false,
          read_at: nil,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])
    end
  end

  test "subscription custom_refresh_interval must be positive when set" do
    feed = insert_feed!()

    assert {:error, changeset} =
             %Subscription{}
             |> Subscription.changeset(%{
               feed_id: feed.id,
               custom_refresh_interval: 0
             })
             |> Repo.insert()

    assert %{custom_refresh_interval: _} = errors_on(changeset)
  end

  test "long feed link is accepted as text" do
    link = "https://example.com/" <> String.duplicate("a", 500) <> ".xml"
    feed = insert_feed!(%{link: link})
    assert feed.link == link
  end
end
