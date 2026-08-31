defmodule Earss.MCP.Tools.CategoriesTest do
  @moduledoc """
  Tests for the category tools.

  The critical behaviour is the two-phase delete: category_delete without
  `confirm: true` reports what is inside and touches nothing; only the
  confirmed call deletes. Deleting a category also must not lose
  subscriptions — they fall back to uncategorised.
  """

  use Earss.DataCase, async: false

  alias Earss.Feeds
  alias Earss.MCP.Handler
  alias Earss.MCP.Tools.Categories
  alias Earss.Reader
  alias Earss.Repo

  setup do
    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/mcp-cat.xml", title: "Cat Feed"})

    {:ok, cat} = Reader.create_category(%{"name" => "Tech", "position" => 1})
    {:ok, sub} = Reader.subscribe(%{feed_id: feed.id, category_id: cat.id, refresh: false})

    %{feed: feed, category: cat, subscription: sub}
  end

  defp tool(name), do: Enum.find(Categories.tools(), &(&1.name == name))

  defp call(name, args \\ %{}), do: tool(name).handler.(args)

  # Two-phase destructive behaviour lives in Earss.MCP.Handler, so the
  # confirmed and unconfirmed paths are exercised through it. The handler
  # returns the shaped result map (content blocks + structuredContent).
  defp call_via_handler(name, args) do
    {:ok, result, _state} = Handler.handle_call_tool(name, args, %{})
    result
  end

  defp structured(result) do
    # text_result mirrors structured content into a text block; reading the
    # structured form directly keeps the assertions off the wire format.
    result["structuredContent"] || result[:structuredContent]
  end

  defp subscription(category_id) do
    import Ecto.Query
    Repo.one(from s in Earss.Reader.Subscription, where: s.category_id == ^category_id)
  end

  describe "category_list/1" do
    test "lists categories with subscription counts" do
      assert {:ok, result} = call("category_list")

      cat = Enum.find(result.categories, &(&1.name == "Tech"))
      assert cat.subscriptions == 1
      assert cat.position == 1
    end

    test "is read-only" do
      assert tool("category_list").mutating == false
    end
  end

  describe "category_create/1" do
    test "creates a category" do
      assert {:ok, result} = call("category_create", %{"name" => "News"})
      assert result.category.name == "News"
    end

    test "rejects a duplicate name" do
      assert {:error, msg} = call("category_create", %{"name" => "Tech"})
      assert msg =~ "has already been taken"
    end

    test "rejects a blank name" do
      assert {:error, _} = call("category_create", %{"name" => "   "})
    end
  end

  describe "category_update/1" do
    test "renames a category", %{category: cat} do
      assert {:ok, result} = call("category_update", %{"id" => cat.id, "name" => "Tech News"})
      assert result.category.name == "Tech News"
    end

    test "errors when nothing is passed", %{category: cat} do
      assert {:error, msg} = call("category_update", %{"id" => cat.id})
      assert msg =~ "nothing to update"
    end

    test "errors on an unknown id" do
      assert {:error, msg} = call("category_update", %{"id" => 999_999, "name" => "X"})
      assert msg =~ "no category"
    end
  end

  describe "category_delete/1 — two-phase" do
    test "without confirm it reports and touches nothing", %{category: cat} do
      report = call_via_handler("category_delete", %{"id" => cat.id}) |> structured()

      assert report.executed == false
      assert report.requires_confirmation == true
      assert report.name == "Tech"
      assert report.subscriptions_to_uncategorise == 1

      # The category and its subscription are still there.
      assert Reader.get_category(cat.id)
      assert subscription(cat.id)
    end

    test "with confirm it deletes and subscriptions survive uncategorised", %{
      category: cat,
      subscription: sub
    } do
      report =
        call_via_handler("category_delete", %{"id" => cat.id, "confirm" => true})
        |> structured()

      assert report.deleted == true
      assert is_nil(Reader.get_category(cat.id))

      # nilify FK, not cascade: the subscription keeps working.
      reloaded = Repo.get!(Earss.Reader.Subscription, sub.id)
      assert reloaded.category_id == nil
    end

    test "reports a missing category instead of erroring" do
      report = call_via_handler("category_delete", %{"id" => 999_999}) |> structured()

      assert report.affected == :none
    end

    test "is marked destructive" do
      assert tool("category_delete").destructive == true
      assert tool("category_list").destructive == false
    end
  end
end
