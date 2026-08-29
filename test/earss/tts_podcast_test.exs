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

  defp get(path), do: json_req(:get, path)
end
