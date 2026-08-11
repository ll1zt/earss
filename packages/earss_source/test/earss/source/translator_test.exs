defmodule Earss.Source.TranslatorTest do
  use ExUnit.Case, async: true
  doctest Earss.Source.Translator

  describe "api_version/0" do
    test "matches the package's adapter contract major" do
      assert Earss.Source.Translator.api_version() == 1
    end
  end

  describe "skip?/2 default" do
    test "returns false (never skip) unless a plugin overrides it" do
      assert Earss.Source.Translator.skip?("hello world", "zh") == false
      assert Earss.Source.Translator.skip?("", "zh") == false
    end
  end
end
