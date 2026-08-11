defmodule Earss.ExportAPITest do
  use Earss.ConnCase

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.Entry
  alias Earss.Reader

  setup do
    {:ok, user} = Reader.create_user("exp_api_#{System.unique_integer([:positive])}", "secret")
    token = login_token(user.username, "secret")
    %{user: user, token: token}
  end

  defp unique_link do
    "https://example.com/exp_#{System.unique_integer([:positive])}.xml"
  end

  defp seed_feed! do
    link = unique_link()

    {:ok, feed} = Feeds.create_feed(%{link: link, title: "Export API Feed"})

    {:ok, _} =
      Feeds.upsert_entries(feed, [
        %{
          link: "#{link}/1",
          guid: "g1",
          title: "One",
          content: "<p>Body one</p>",
          published_at: ~U[2026-08-01 10:00:00Z]
        }
      ])

    feed
  end

  defp seed_starred!(user) do
    feed = seed_feed!()
    {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})
    [entry] = Repo.all(Entry)
    {:ok, _} = Reader.set_star(user, entry.id, true)
    {feed, entry}
  end

  test "starred export json", %{user: user, token: token} do
    {_feed, entry} = seed_starred!(user)

    conn = json_req(:get, "/api/export/starred?format=json", nil, auth_header(token))
    assert conn.status == 200
    assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")

    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "earss-starred-#{user.username}"

    decoded = Jason.decode!(conn.resp_body)
    assert decoded["scope"] == "starred"
    assert decoded["user"] == user.username

    assert [row] = decoded["entries"]
    assert row["entry_id"] == entry.id
    assert row["title"] == "One"
    assert row["content"] == "<p>Body one</p>"
    assert row["feed_title"] == "Export API Feed"
    assert row["is_star"] == true
  end

  test "starred export markdown", %{user: user, token: token} do
    seed_starred!(user)

    conn = json_req(:get, "/api/export/starred?format=markdown", nil, auth_header(token))
    assert conn.status == 200
    assert ["text/markdown; charset=utf-8"] = get_resp_header(conn, "content-type")

    body = conn.resp_body
    assert body =~ "# Earss export"
    assert body =~ "## One"
    assert body =~ "Body one"
    assert body =~ "- Link:"
    refute body =~ "<p>"
  end

  test "starred export defaults to json", %{user: user, token: token} do
    seed_starred!(user)
    conn = json_req(:get, "/api/export/starred", nil, auth_header(token))
    assert conn.status == 200
    assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")
  end

  test "starred export is empty when nothing starred", %{token: token} do
    conn = json_req(:get, "/api/export/starred", nil, auth_header(token))
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["entries"] == []
  end

  test "feed export requires subscription", %{user: user, token: token} do
    feed = seed_feed!()

    conn = json_req(:get, "/api/export/feed/#{feed.id}", nil, auth_header(token))
    assert conn.status == 404

    {:ok, _} = Reader.subscribe(user, %{feed_id: feed.id, refresh: false})

    conn = json_req(:get, "/api/export/feed/#{feed.id}?format=markdown", nil, auth_header(token))
    assert conn.status == 200

    body = conn.resp_body
    assert body =~ "# Earss export"
    assert body =~ "## One"
    assert body =~ "- Feed: Export API Feed"
  end

  test "all export requires admin and sub_users are forbidden", %{user: user, token: token} do
    _feed = seed_feed!()

    {:ok, sub} = Reader.create_sub_user("exp_sub_#{System.unique_integer([:positive])}", "secret")
    sub_token = login_token(sub.username, "secret")

    conn = json_req(:get, "/api/export/all", nil, auth_header(sub_token))
    assert conn.status == 403

    conn = json_req(:get, "/api/export/all", nil, auth_header(token))
    assert conn.status == 200

    decoded = Jason.decode!(conn.resp_body)
    assert decoded["scope"] == "all"
    assert decoded["user"] == nil
    assert length(decoded["entries"]) == 1
    assert decoded["entries"] |> hd() |> Map.get("is_star") == nil
    _ = user
  end

  test "export routes require auth" do
    conn = json_req(:get, "/api/export/starred")
    assert conn.status == 401

    conn = json_req(:get, "/api/export/all")
    assert conn.status == 401
  end
end
