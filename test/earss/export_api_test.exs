defmodule Earss.ExportAPITest do
  use Earss.ConnCase, async: true

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.Entry
  alias Earss.Reader

  setup do
    token = login_token()
    %{token: token}
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

  defp seed_starred! do
    feed = seed_feed!()
    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
    [entry] = Repo.all(Entry)
    {:ok, _} = Reader.set_star(entry.id, true)
    {feed, entry}
  end

  test "starred export json", %{token: token} do
    {_feed, entry} = seed_starred!()

    conn = json_req(:get, "/api/export/starred?format=json", nil, auth_header(token))
    assert conn.status == 200
    assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")

    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "earss-starred"

    decoded = Jason.decode!(conn.resp_body)
    assert decoded["scope"] == "starred"

    assert [row] = decoded["entries"]
    assert row["entry_id"] == entry.id
    assert row["title"] == "One"
    assert row["content"] == "<p>Body one</p>"
    assert row["feed_title"] == "Export API Feed"
    assert row["is_star"] == true
  end

  test "starred export markdown", %{token: token} do
    seed_starred!()

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

  test "starred export defaults to json", %{token: token} do
    seed_starred!()
    conn = json_req(:get, "/api/export/starred", nil, auth_header(token))
    assert conn.status == 200
    assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")
  end

  test "starred export is empty when nothing starred", %{token: token} do
    conn = json_req(:get, "/api/export/starred", nil, auth_header(token))
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["entries"] == []
  end

  test "feed export requires subscription", %{token: token} do
    feed = seed_feed!()

    conn = json_req(:get, "/api/export/feed/#{feed.id}", nil, auth_header(token))
    assert conn.status == 404

    {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})

    conn = json_req(:get, "/api/export/feed/#{feed.id}?format=markdown", nil, auth_header(token))
    assert conn.status == 200

    body = conn.resp_body
    assert body =~ "# Earss export"
    assert body =~ "## One"
    assert body =~ "- Feed: Export API Feed"
  end

  test "all export is open to the single operator", %{token: token} do
    _feed = seed_feed!()

    conn = json_req(:get, "/api/export/all", nil, auth_header(token))
    assert conn.status == 200

    decoded = Jason.decode!(conn.resp_body)
    assert decoded["scope"] == "all"
    assert length(decoded["entries"]) == 1
    assert decoded["entries"] |> hd() |> Map.get("is_star") == nil
  end

  test "export routes require auth" do
    conn = json_req(:get, "/api/export/starred")
    assert conn.status == 401

    conn = json_req(:get, "/api/export/all")
    assert conn.status == 401
  end
end
