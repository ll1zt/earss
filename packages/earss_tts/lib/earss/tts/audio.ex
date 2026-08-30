defmodule Earss.TTS.Audio do
  @moduledoc """
  Pure audio helpers shared by the host and providers (no I/O).

  Covers content-type mapping and coarse duration estimation from
  bitrate/bytes — the host stores `audio_duration_secs` on `tts_requests`
  for the podcast `itunes:duration` tag, so providers only need to report
  bytes and format.
  """

  @doc """
  Content type for a format token (`"mp3"`, `"m4a"`, `"wav"`, `"ogg"`).

  Falls back to `application/octet-stream` for unknown formats.
  """
  @spec content_type(String.t()) :: String.t()
  def content_type(format) do
    case String.downcase(format) do
      "mp3" -> "audio/mpeg"
      "m4a" -> "audio/mp4"
      "aac" -> "audio/aac"
      "wav" -> "audio/wav"
      "ogg" -> "audio/ogg"
      "opus" -> "audio/ogg"
      "flac" -> "audio/flac"
      _ -> "application/octet-stream"
    end
  end

  @doc """
  Coarse duration in seconds from bytes + format.

  Uses per-format bitrate assumptions (mp3 128kbps, aac/m4a 96kbps, ogg
  96kbps, wav 1411kbps); returns `nil` for unknown formats. The podcast
  `itunes:duration` tolerates slight under/over-estimates.
  """
  @spec estimate_duration_secs(pos_integer(), String.t()) :: pos_integer() | nil
  def estimate_duration_secs(bytes, format) when is_integer(bytes) and bytes > 0 do
    case bits_per_second(format) do
      nil -> nil
      bps -> max(div(bytes * 8, bps), 1)
    end
  end

  def estimate_duration_secs(_, _), do: nil

  @doc """
  Format a duration in seconds as `mm:ss` or `h:mm:ss` (itunes:duration).
  """
  @spec format_duration(pos_integer() | nil) :: String.t()
  def format_duration(nil), do: "0:00"

  def format_duration(secs) when is_integer(secs) and secs >= 0 do
    h = div(secs, 3600)
    m = div(rem(secs, 3600), 60)
    s = rem(secs, 60)

    if h > 0 do
      "#{h}:#{pad(m)}:#{pad(s)}"
    else
      "#{m}:#{pad(s)}"
    end
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: to_string(n)

  defp bits_per_second(format) do
    case String.downcase(format) do
      f when f in ["mp3"] -> 128_000
      f when f in ["m4a", "aac", "ogg", "opus"] -> 96_000
      f when f in ["wav"] -> 1_411_200
      _ -> nil
    end
  end
end
