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

  test "neutralizes entity-encoded javascript: URLs" do
    dirty = ~S[<a href="javascript&#58;alert(1)">dec</a>]
    clean = HTMLSanitize.sanitize(dirty)
    refute clean =~ "javascript"

    dirty_hex = ~S[<a href="java&#x73;cript:alert(1)">hex</a>]
    refute HTMLSanitize.sanitize(dirty_hex) =~ "javascript"

    dirty_named = ~S[<a href="javascript&colon;alert(1)">named</a>]
    refute HTMLSanitize.sanitize(dirty_named) =~ "javascript"
  end

  test "neutralizes control-character-obfuscated schemes" do
    dirty = ~S[<a href="java&#9;script:alert(1)">tab</a>]
    refute HTMLSanitize.sanitize(dirty) =~ "javascript"

    dirty_nl = ~S[<a href="java&#10;script:alert(1)">nl</a>]
    refute HTMLSanitize.sanitize(dirty_nl) =~ "javascript"
  end

  test "drops svg and math trees entirely" do
    dirty =
      ~S[<p>ok</p><svg><a xlink:href="javascript:alert(1)"><text>click</text></a></svg><math><mi>x</mi></math>]

    clean = HTMLSanitize.sanitize(dirty)
    refute clean =~ "svg"
    refute clean =~ "math"
    refute clean =~ "click"
    assert clean =~ "ok"
  end

  test "keeps safe urls" do
    dirty = ~S[<a href="https://ok.example/p?x=1&amp;y=2">ok</a>]
    clean = HTMLSanitize.sanitize(dirty)
    assert clean =~ "https://ok.example"
  end

  test "neutralizes file: and script-capable data: URLs" do
    dirty =
      ~S[<a href="file:///etc/passwd">f</a><a href="data:image/svg+xml,<svg onload=alert(1)>">s</a>]

    clean = HTMLSanitize.sanitize(dirty)
    refute clean =~ "file:"
    refute clean =~ "data:image/svg"
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
