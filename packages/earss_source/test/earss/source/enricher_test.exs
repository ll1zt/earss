defmodule Earss.Source.EnricherTest do
  use ExUnit.Case, async: true
  doctest Earss.Source.Enricher

  describe "api_version/0" do
    test "matches the package's adapter contract major" do
      assert Earss.Source.Enricher.api_version() == 1
    end
  end

  describe "skip?/2 default" do
    test "returns false (never skip) unless a plugin overrides it" do
      assert Earss.Source.Enricher.skip?(%{content: "hello"}, target_lang: "zh") == false
      assert Earss.Source.Enricher.skip?(%{content: ""}, target_lang: "zh") == false
    end
  end
end
