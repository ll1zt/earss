defmodule Earss.Translate.HTMLTest do
  use ExUnit.Case, async: true

  alias Earss.Translate.HTML

  describe "extract_blocks/1" do
    test "splits block elements into translation units" do
      html = "<h2>Title</h2><p>First paragraph.</p><p>Second.</p>"

      assert {:ok, [h2, p1, p2]} = HTML.extract_blocks(html)
      assert h2.type == :block and h2.tag == "h2" and h2.text == "Title"
      assert p1.type == :block and p1.tag == "p" and p1.text == "First paragraph."
      assert p2.type == :block and p2.tag == "p" and p2.text == "Second."
    end

    test "keeps list items and blockquotes as units" do
      html = "<ul><li>One</li><li>Two</li></ul><blockquote>Quote</blockquote>"

      assert {:ok, blocks} = HTML.extract_blocks(html)

      assert Enum.map(blocks, &{&1.tag, &1.text}) == [
               {"li", "One"},
               {"li", "Two"},
               {"blockquote", "Quote"}
             ]
    end

    test "replaces inline elements with placeholder tokens" do
      html = ~s(<p>See <a href="https://x.com">X</a> and <strong>bold</strong>.</p>)

      assert {:ok, [block]} = HTML.extract_blocks(html)
      assert block.text == "See ⟦0⟧ and ⟦1⟧."
      assert block.placeholders["0"] == ~s(<a href="https://x.com">X</a>)
      assert block.placeholders["1"] == "<strong>bold</strong>"
    end

    test "unwraps style-only tags so their text is translated" do
      html = "<p><span class=\"x\">Hello</span> <b>world</b> <i>!</i></p>"

      assert {:ok, [block]} = HTML.extract_blocks(html)
      assert block.text == "Hello world !"
      assert block.placeholders == %{}
    end

    test "keeps pre/code blocks raw and untranslated" do
      html = "<p>Intro</p><pre><code>def foo, do: 1</code></pre>"

      assert {:ok, [intro, raw]} = HTML.extract_blocks(html)
      assert intro.type == :block
      assert raw.type == :raw and raw.text =~ "def foo, do: 1"
    end

    test "treats a container with bare text as one block" do
      html = "<div>Bare text here</div>"

      assert {:ok, [block]} = HTML.extract_blocks(html)
      assert block.type == :block and block.tag == "div" and block.text == "Bare text here"
    end

    test "recurses containers that hold block elements" do
      html = "<div><p>A</p><p>B</p></div>"

      assert {:ok, blocks} = HTML.extract_blocks(html)
      assert Enum.map(blocks, & &1.text) == ["A", "B"]
    end

    test "returns empty block list for empty input" do
      assert {:ok, []} = HTML.extract_blocks("")
      assert {:error, :invalid_input} = HTML.extract_blocks(nil)
    end
  end

  describe "render_block/2" do
    test "restores placeholders and wraps in the original tag" do
      html = ~s(<p>See <a href="https://x.com">X</a>.</p>)

      assert {:ok, [block]} = HTML.extract_blocks(html)

      assert {:ok, rendered} =
               HTML.render_block("看看 ⟦0⟧。", block)

      assert rendered == ~s(<p>看看 <a href="https://x.com">X</a>。</p>)
    end

    test "allows placeholder reordering" do
      html = ~s(<p><a href="/a">A</a> and <a href="/b">B</a></p>)
      assert {:ok, [block]} = HTML.extract_blocks(html)
      assert block.text == "⟦0⟧ and ⟦1⟧"

      assert {:ok, rendered} = HTML.render_block("⟦1⟧ 与 ⟦0⟧", block)
      assert rendered == ~s(<p><a href="/b">B</a> 与 <a href="/a">A</a></p>)
    end

    test "passes text blocks through untouched" do
      assert {:ok, "你好"} = HTML.render_block("你好", %{type: :text, text: "hi"})
    end

    test "returns raw blocks untouched" do
      block = %{type: :raw, tag: "pre", attrs: [], text: "<pre><code>x</code></pre>"}
      assert {:ok, "<pre><code>x</code></pre>"} = HTML.render_block("anything", block)
    end

    test "rejects dropped placeholders" do
      html = "<p>⟦0⟧ and ⟦1⟧</p>"
      assert {:ok, [block]} = HTML.extract_blocks(html)
      assert {:error, :placeholder_mismatch} = HTML.render_block("只保留了 ⟦0⟧", block)
    end

    test "rejects duplicated placeholders" do
      html = "<p>⟦0⟧</p>"
      assert {:ok, [block]} = HTML.extract_blocks(html)
      assert {:error, :placeholder_mismatch} = HTML.render_block("⟦0⟧ ⟦0⟧", block)
    end
  end

  describe "to_plain_text/1" do
    test "strips markup and trims" do
      assert HTML.to_plain_text("<p>Hello <strong>world</strong>!</p>") == "Hello world!"
    end

    test "survives unparseable input" do
      # Floki parses leniently; text is still extracted
      assert HTML.to_plain_text("<p>unclosed") == "unclosed"
    end
  end
end
