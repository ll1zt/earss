defmodule Earss.TtsPodcastTest do
  use Earss.ConnCase, async: false

  alias Earss.Feeds
  alias Earss.Repo
  alias Earss.TTS

  @audio_dir System.tmp_dir!() |> Path.join("earss-tts-podcast-test")

  setup do
    Application.put_env(:earss, :tts,
      audio_dir: @audio_dir,
      podcast: %{
        title: "My <Queue> & More",
        description: "Test feed",
        author: "operator",
        language: "zh-cn"
      }
    )

    on_exit(fn ->
      File.rm_rf!(@audio_dir)
      Application.delete_env(:earss, :tts)
    end)

    File.mkdir_p!(@audio_dir)

    {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/podcast.xml"})

    {:ok, %{entries: [entry, other]}} =
      Feeds.upsert_entries(feed, [
        %{
          guid: "podcast-1",
          link: "https://example.com/a & b",
          title: "Episode <One> & \"Two\"",
          content: "<p>Text</p>"
        },
        %{
          guid: "podcast-2",
          link: "https://example.com/b",
          title: "Pending one",
          content: "<p>x</p>"
        }
      ])

    {:ok, ready} = TTS.record_request(entry.id)
    {:ok, _pending} = TTS.record_request(other.id)

    # Only the first request is ready with audio on disk.
    File.write!(Path.join(@audio_dir, "#{entry.id}.mp3"), "ID3fakeaudio")

    ready
    |> Ecto.Changeset.change(
      state: :ready,
      provider: "fake-tts",
      audio_path: "#{entry.id}.mp3",
      audio_bytes: 12,
      audio_duration_secs: 95
    )
    |> Repo.update!()

    %{entry_id: entry.id}
  end

  test "rss.xml lists ready requests with proper escapes and metadata" do
    conn = get("/podcast/rss.xml")

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> hd() =~ "application/xml"

    body = conn.resp_body
    assert body =~ "My &lt;Queue&gt; &amp; More"
    assert body =~ "<language>zh-cn</language>"
    assert body =~ "Episode &lt;One&gt; &amp; &quot;Two&quot;"
    assert body =~ ~s(<guid isPermaLink="false">earss-tts-)
    assert body =~ ~s(length="12" type="audio/mpeg")
    assert body =~ "1:35"
    refute body =~ "Pending one"
  end

  test "rss.xml is well-formed XML" do
    conn = get("/podcast/rss.xml")

    {doc, _rest} = :xmerl_scan.string(String.to_charlist(conn.resp_body))

    titles =
      :xmerl_xpath.string('/rss/channel/item/title/text()', doc)
      |> Enum.map(&(&1 |> elem(4) |> List.to_string()))

    # xmerl decodes entities — parsed values equal the original titles.
    assert "Episode <One> & \"Two\"" in titles
  end

  test "audio serves the stored file with the right content type", %{entry_id: entry_id} do
    conn = get("/podcast/audio/#{entry_id}.mp3")

    assert conn.status == 200
    assert conn.resp_body == "ID3fakeaudio"
    assert conn |> get_resp_header("content-type") |> hd() =~ "audio/mpeg"
  end

  test "audio rejects path traversal and unknown files" do
    assert get("/podcast/audio/../earss.env").status == 404
    assert get("/podcast/audio/999999.mp3").status == 404
    assert get("/podcast/audio/999999.txt").status == 404
  end

  test "serves byte ranges (Apple Podcasts probes with Range: bytes=0-1)", %{
    entry_id: entry_id
  } do
    conn = get("/podcast/audio/#{entry_id}.mp3", [{"range", "bytes=0-1"}])

    assert conn.status == 206
    assert conn |> get_resp_header("content-range") |> hd() =~ ~r/^bytes 0-1\/12$/
    assert conn |> get_resp_header("accept-ranges") |> hd() == "bytes"
    assert conn.resp_body == "ID"
  end

  test "serves open-ended and suffix ranges", %{entry_id: entry_id} do
    open = get("/podcast/audio/#{entry_id}.mp3", [{"range", "bytes=8-"}])
    assert open.status == 206
    assert open |> get_resp_header("content-range") |> hd() == "bytes 8-11/12"

    suffix = get("/podcast/audio/#{entry_id}.mp3", [{"range", "bytes=-4"}])
    assert suffix.status == 206
    assert suffix |> get_resp_header("content-range") |> hd() == "bytes 8-11/12"
  end

  test "unsatisfiable range is a 416, not a crash", %{entry_id: entry_id} do
    conn = get("/podcast/audio/#{entry_id}.mp3", [{"range", "bytes=99999-"}])

    assert conn.status == 416
    assert conn |> get_resp_header("content-range") |> hd() == "bytes */12"
  end

  test "HEAD returns headers without a body", %{entry_id: entry_id} do
    conn = json_req(:head, "/podcast/audio/#{entry_id}.mp3")

    assert conn.status == 200
    assert conn |> get_resp_header("accept-ranges") |> hd() == "bytes"
    assert conn |> get_resp_header("content-length") |> hd() == "12"
    assert conn.resp_body == ""
  end

  test "audio content-type carries no charset (strict players reject it)", %{
    entry_id: entry_id
  } do
    conn = get("/podcast/audio/#{entry_id}.mp3")

    assert conn |> get_resp_header("content-type") |> hd() == "audio/mpeg"
  end

  test "cover 404s and the feed omits itunes:image when none is configured" do
    assert get("/podcast/cover.jpg").status == 404
    refute get("/podcast/rss.xml").resp_body =~ "itunes:image"
  end

  test "cover is served and advertised when configured" do
    cover = Path.join(@audio_dir, "cover.jpg")
    File.write!(cover, "jpeg-bytes")

    Application.put_env(:earss, :tts,
      audio_dir: @audio_dir,
      podcast: %{cover_path: cover}
    )

    assert get("/podcast/cover.jpg").resp_body == "jpeg-bytes"
    assert get("/podcast/rss.xml").resp_body =~ "itunes:image"
  end

  test "the feed declares itunes:explicit (Apple requires the tag)" do
    assert get("/podcast/rss.xml").resp_body =~ "<itunes:explicit>false</itunes:explicit>"
  end

  defp get(path), do: json_req(:get, path)

  defp get(path, headers), do: json_req(:get, path, nil, headers)
end
