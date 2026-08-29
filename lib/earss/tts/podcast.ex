defmodule Earss.TTS.Podcast do
  @moduledoc """
  Apple-Podcasts-compatible RSS feed over ready TTS requests, plus media
  serving (docs: the "listen later" pipeline).

  Endpoints (unauthenticated by design — podcast clients and Apple's
  crawler cannot log in; the feed only exposes synthesized audio of the
  operator's own listening queue):

    * `GET /podcast/rss.xml` — the feed
    * `GET|HEAD /podcast/audio/<entry_id>.<ext>` — one audio file
    * `GET /podcast/cover.jpg` — optional show artwork

  ## Playback requirements honoured here

  Apple Podcasts streams via AVPlayer, which requires the media server to
  support **HEAD requests and byte-range requests** (it probes with
  `Range: bytes=0-1` and then streams with 206 responses). Serving the whole
  file as a plain 200 makes playback spin forever — the exact symptom this
  module's `send_range/3` avoids.

  Feed metadata comes from `config :earss, :tts, :podcast` (`title`,
  `description`, `author`, `language`, `explicit`, `cover_path`); enclosure
  URLs reuse the listen-link base resolution (configured `public_url` wins,
  else the request's own scheme/host) so the feed works unchanged behind
  tunnels and proxies.
  """

  import Ecto.Query, warn: false

  import Plug.Conn,
    only: [put_resp_content_type: 2, put_resp_header: 3, send_resp: 3, send_file: 5]

  alias Earss.Repo
  alias Earss.TTS.Request

  @extensions ~w(mp3 m4a aac wav ogg flac)
  @max_age 60

  # —— HTTP handlers ——

  def rss(conn) do
    base = Earss.API.ListenControls.request_base(conn)

    xml =
      Request
      |> where([r], r.state == :ready and not is_nil(r.audio_path))
      |> join(:inner, [r], e in Earss.Feeds.Entry, on: e.id == r.entry_id)
      |> order_by([r], desc: r.updated_at)
      |> limit(500)
      |> select([r, e], %{
        entry_id: r.entry_id,
        title: e.title,
        link: e.link,
        published_at: e.published_at,
        audio_path: r.audio_path,
        audio_bytes: r.audio_bytes,
        audio_duration_secs: r.audio_duration_secs,
        updated_at: r.updated_at
      })
      |> Repo.all()
      |> items(base)
      |> channel(podcast_config(), base)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, xml)
  end

  def audio(conn, glob) do
    with [filename] when is_binary(filename) <- List.wrap(glob),
         filename <- URI.decode(filename),
         true <- Regex.match?(~r|^\d+\.(#{Enum.join(@extensions, "|")})$|, filename),
         %Request{state: :ready, audio_path: filename} <-
           Repo.get_by(Request, audio_path: filename, state: :ready),
         audio_dir when is_binary(audio_dir) <- Keyword.get(tts_config(), :audio_dir),
         path <- Path.join(audio_dir, filename),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      conn
      # put_resp_content_type/2 appends `; charset=utf-8`, which strict
      # players reject for media — set the header directly instead.
      |> put_resp_header("content-type", content_type(filename))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("cache-control", "public, max-age=#{@max_age}")
      |> send_range(path, size)
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "not found")
    end
  end

  @doc """
  Show artwork: serves `podcast.cover_path` when it points at a readable
  file, otherwise 404. The feed omits `itunes:image` in that case so it
  never advertises a missing image.
  """
  def cover(conn) do
    case cover_path() do
      path when is_binary(path) ->
        conn
        |> put_resp_content_type("image/jpeg")
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_resp(200, File.read!(path))

      nil ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "no cover configured")
    end
  end

  # —— byte-range media responses ——

  # 206 for a satisfiable Range header, 200 for a plain GET, 416 when the
  # range is out of bounds. HEAD keeps the headers but sends no body.
  defp send_range(conn, path, size) do
    case Plug.Conn.get_req_header(conn, "range") do
      [] ->
        conn
        |> put_resp_header("content-length", Integer.to_string(size))
        |> send_body(200, path, 0, size)

      [range | _] ->
        case parse_range(range, size) do
          {:ok, offset, length} ->
            conn
            |> put_resp_header("content-range", "bytes #{offset}-#{offset + length - 1}/#{size}")
            |> put_resp_header("content-length", Integer.to_string(length))
            |> send_body(206, path, offset, length)

          :unsatisfiable ->
            conn
            |> put_resp_header("content-range", "bytes */#{size}")
            |> send_resp(416, "range not satisfiable")

          # Multi-range or malformed: fall back to the whole file.
          :ignore ->
            conn
            |> put_resp_header("content-length", Integer.to_string(size))
            |> send_body(200, path, 0, size)
        end
    end
  end

  # A HEAD response carries the same headers but no body.
  defp send_body(%{method: "HEAD"} = conn, status, _path, _offset, _length) do
    send_resp(conn, status, "")
  end

  defp send_body(conn, status, path, offset, length) do
    send_file(conn, status, path, offset, length)
  end

  # `bytes=start-end`, `bytes=start-`, `bytes=-suffix`. Only single-range
  # requests are honoured (players do not use multi-range).
  defp parse_range("bytes=" <> spec, size) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] ->
        with {n, ""} <- Integer.parse(suffix), true <- n > 0 do
          length = min(n, size)
          {:ok, size - length, length}
        else
          _ -> :ignore
        end

      [start, rest] ->
        with {first, ""} <- Integer.parse(start),
             true <- first < size,
             last <- range_end(rest, size),
             true <- last >= first do
          {:ok, first, min(last, size - 1) - first + 1}
        else
          _ -> :unsatisfiable
        end

      _ ->
        :ignore
    end
  end

  defp parse_range(_, _size), do: :ignore

  defp range_end("", size), do: size - 1

  defp range_end(value, size) do
    case Integer.parse(value) do
      {n, ""} -> min(n, size - 1)
      _ -> size - 1
    end
  end

  defp content_type(filename) do
    ext = Path.extname(filename) |> String.trim_leading(".")
    Earss.TTS.Audio.content_type(ext)
  end

  # —— feed rendering ——

  defp items(rows, base) do
    Enum.map_join(rows, "", fn row ->
      url = "#{base}/podcast/audio/#{row.audio_path}"

      """
      <item>
        <title>#{escape(row.title || "(untitled)")}</title>
        <link>#{escape(row.link || "")}</link>
        <guid isPermaLink="false">earss-tts-#{row.entry_id}</guid>
        <pubDate>#{rfc2822(row.published_at || row.updated_at)}</pubDate>
        <enclosure url="#{escape(url)}" length="#{row.audio_bytes || 0}" type="#{content_type(row.audio_path)}"/>
        <itunes:duration>#{Earss.TTS.Audio.format_duration(row.audio_duration_secs)}</itunes:duration>
      </item>
      """
    end)
  end

  defp channel(items, cfg, base) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title>#{escape(cfg.title)}</title>
        <description>#{escape(cfg.description)}</description>
        <link>#{escape(base)}</link>
        <language>#{escape(cfg.language)}</language>
        <itunes:author>#{escape(cfg.author)}</itunes:author>
        <itunes:explicit>#{cfg.explicit}</itunes:explicit>
        #{image_tag(base)}
        <generator>earss</generator>
        #{items}
      </channel>
    </rss>
    """
  end

  # Only advertise artwork when a cover file is actually reachable.
  defp image_tag(base) do
    if cover_path(),
      do: ~s(<itunes:image href="#{escape("#{base}/podcast/cover.jpg")}"/>),
      else: ""
  end

  defp podcast_config do
    cfg = Keyword.get(tts_config(), :podcast, %{})

    %{
      title: get(cfg, :title, "Earss Listening Queue"),
      description: get(cfg, :description, "Articles saved for listening, synthesized by earss"),
      author: get(cfg, :author, "earss"),
      language: get(cfg, :language, "en-us"),
      explicit: if(get(cfg, :explicit, false), do: "true", else: "false")
    }
  end

  defp cover_path do
    case get(Keyword.get(tts_config(), :podcast, %{}), :cover_path, nil) do
      path when is_binary(path) and path != "" ->
        if File.exists?(path), do: path, else: nil

      _ ->
        nil
    end
  end

  defp tts_config, do: Application.get_env(:earss, :tts, [])

  defp get(cfg, key, default) when is_map(cfg), do: Map.get(cfg, key, default)
  defp get(cfg, key, default) when is_list(cfg), do: Keyword.get(cfg, key, default)

  defp rfc2822(%DateTime{} = dt), do: Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")

  defp rfc2822(%NaiveDateTime{} = dt) do
    DateTime.from_naive!(dt, "Etc/UTC") |> rfc2822()
  end

  defp rfc2822(_), do: Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")

  defp escape(binary) do
    binary
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
