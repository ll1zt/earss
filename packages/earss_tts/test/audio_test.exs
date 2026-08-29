defmodule Earss.TTS.AudioTest do
  use ExUnit.Case, async: true

  alias Earss.TTS.Audio

  test "content types" do
    assert Audio.content_type("mp3") == "audio/mpeg"
    assert Audio.content_type("m4a") == "audio/mp4"
    assert Audio.content_type("wav") == "audio/wav"
    assert Audio.content_type("nope") == "application/octet-stream"
  end

  test "duration estimation from bytes" do
    # 128kbps mp3: 1 minute ≈ 128_000 * 60 / 8 bytes = 960_000
    assert Audio.estimate_duration_secs(960_000, "mp3") == 60
    assert Audio.estimate_duration_secs(0, "mp3") == nil
    assert Audio.estimate_duration_secs(100, "nope") == nil
  end

  test "format duration" do
    assert Audio.format_duration(0) == "0:00"
    assert Audio.format_duration(59) == "0:59"
    assert Audio.format_duration(60) == "1:00"
    assert Audio.format_duration(3_661) == "1:01:01"
    assert Audio.format_duration(nil) == "0:00"
  end
end
