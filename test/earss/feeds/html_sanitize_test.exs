defmodule Earss.Feeds.HTMLSanitizeTest do
  use Earss.DataCase

  alias Earss.Feeds
  alias Earss.Feeds.HTMLSanitize

  setup do
    Application.put_env(:earss, :html_sanitize, enabled: true)
    :ok
  end

  test "strips script tags and event handlers" do
    dirty =
      ~S[<p>hi</p><script>alert(1)</script><a href="https://ok.example" onclick="x()">ok</a>]

    clean = HTMLSanitize.sanitize(dirty)

    refute clean =~ "script"
    refute clean =~ "onclick"
    assert clean =~ "hi"
    assert clean =~ "https://ok.example"
  end

  test "neutralizes javascript: URLs" do
    dirty = ~S[<a href="javascript:alert(1)">x</a><img src="JaVaScRiPt:evil">]
    clean = HTMLSanitize.sanitize(dirty)
    refute clean =~ "javascript"
  end

  test "upsert_entry sanitizes content and summary" do
    {:ok, feed} = Feeds.create_feed(%{link: "https://sanitize.example/feed.xml", title: "S"})

    {:ok, entry} =
      Feeds.upsert_entry(feed, %{
        link: "https://sanitize.example/1",
        guid: "g1",
        title: "T",
        summary: ~S[<b>sum</b><script>bad</script>],
        content: ~S[<p>body</p><iframe src="https://evil"></iframe>]
      })

    refute entry.summary =~ "script"
    assert entry.summary =~ "sum"
    refute entry.content =~ "iframe"
    assert entry.content =~ "body"
  end

  test "can be disabled via config" do
    Application.put_env(:earss, :html_sanitize, enabled: false)
    on_exit(fn -> Application.put_env(:earss, :html_sanitize, enabled: true) end)

    dirty = ~S[<script>x</script>]
    assert HTMLSanitize.sanitize(dirty) == dirty
  end
end
