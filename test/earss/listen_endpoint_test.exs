defmodule Earss.ListenEndpointTest do
  use Earss.ConnCase

  alias Earss.Feeds
  alias Earss.TTS
  alias Earss.TTS.Link

  setup do
    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/listen_test.xml"})

    {:ok, %{entries: [entry]}} =
      Feeds.upsert_entries(feed, [
        %{
          guid: "listen-test-1",
          link: "https://example.com/listen-test-1",
          title: "A <great> article & more",
          content: "<p>Hello</p>"
        }
      ])

    %{entry_id: entry.id}
  end

  test "a valid signed link records the request and confirms", %{entry_id: entry_id} do
    conn = get("/tts/listen/#{entry_id}?sig=#{Link.sign(entry_id)}")

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> hd() =~ "text/html"

    # Title is escaped, never raw.
    assert conn.resp_body =~ "&lt;great&gt; article &amp; more"
    assert [%{entry_id: ^entry_id}] = TTS.list_requests()
  end

  test "repeated clicks are idempotent", %{entry_id: entry_id} do
    sig = Link.sign(entry_id)
    get("/tts/listen/#{entry_id}?sig=#{sig}")

    conn = get("/tts/listen/#{entry_id}?sig=#{sig}")
    assert conn.status == 200
    assert [_one_row] = TTS.list_requests()
  end

  test "forged signature is rejected and stores nothing", %{entry_id: entry_id} do
    conn =
      get("/tts/listen/#{entry_id}?sig=#{String.slice(Link.sign(entry_id), 0..8)}.bogus")

    assert conn.status == 403
    assert [] == TTS.list_requests()
  end

  test "missing signature is rejected" do
    assert get("/tts/listen/1").status == 403
  end

  test "valid signature for an unknown entry returns 404" do
    assert get("/tts/listen/9_999_999?sig=#{Link.sign(9_999_999)}").status == 404
  end

  defp get(path), do: json_req(:get, path)
end
