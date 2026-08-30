defmodule Earss.TTS.LangTest do
  use ExUnit.Case, async: true

  alias Earss.TTS.Lang

  test "detects Chinese (CJK-heavy, kana-free)" do
    assert Lang.script("这是一篇中文文章，讲的是新闻。") == :zh
    assert Lang.to_lang(:zh) == "zh"
  end

  test "detects Japanese by kana" do
    assert Lang.script("これは日本語の記事です。ニュースをお届けします。") == :ja
    assert Lang.to_lang(:ja) == "ja"
  end

  test "detects Korean by hangul" do
    assert Lang.script("이것은 한국어 기사입니다.") == :ko
    assert Lang.to_lang(:ko) == "ko"
  end

  test "detects latin text" do
    assert Lang.script("This is an English article about technology.") == :latin
    assert Lang.to_lang(:latin) == "en"
  end

  test "returns other for empty or ambiguous text" do
    assert Lang.script("") == :other
    assert Lang.script("1234567890!@#$%^&*()") == :other
    assert Lang.to_lang(:other) == nil
  end

  test "mixed Chinese with Japanese kana is Japanese, not Chinese" do
    # shares Han characters but has kana — must not be treated as zh
    assert Lang.script("中国語の記事ですがカナが混じっていますね") == :ja
  end
end
