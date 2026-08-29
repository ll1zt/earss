defmodule Earss.TTS.Podcast do
  @moduledoc """
  Apple-Podcasts-compatible RSS feed over ready TTS requests, plus audio
  file serving (docs: the "listen later" pipeline).

  Endpoints (unauthenticated by design — podcast clients and Apple's
  crawler cannot log in; the feed only exposes synthesized audio of the
  operator's own listening queue):

    * `GET /podcast/rss.xml` — the feed
    * `GET /podcast/audio/<entry_id>.<ext>` — one audio file

  Feed metadata comes from `config :earss, :tts, :podcast`
  (`title`, `description`, `author`, `language`); enclosure URLs reuse the
  listen-link base resolution (configured `public_url` wins, else the
  request's own scheme/host) so the feed works unchanged behind tunnels
  and proxies.
  """

  import Ecto.Query, warn: false

  import Plug.Conn,
    only: [put_resp_content_type: 2, put_resp_header: 3, send_resp: 3]

  alias Earss.Repo
  alias Earss.TTS.Request

  @extensions ~w(mp3 m4a aac wav ogg flac)
  @max_age 60

  # —— HTTP handlers ——

  def rss(conn) do
    base = Earss.API.ListenControls.request_base(conn)
    cfg = podcast_config()

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
      |> channel(cfg, base)

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
         audio_dir when is_binary(audio_dir) <-
           Application.get_env(:earss, :tts, []) |> Keyword.get(:audio_dir),
         true <- File.exists?(Path.join(audio_dir, filename)) do
      conn
      # put_resp_content_type/2 appends `; charset=utf-8`, which strict
      # players reject for media — set the header directly instead.
      |> put_resp_header("content-type", content_type(filename))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("cache-control", "public, max-age=#{@max_age}")
      |> send_resp(200, File.read!(Path.join(audio_dir, filename)))
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "not found")
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
        <language>#{escape(cfg.language)}</language>
        <itunes:author>#{escape(cfg.author)}</itunes:author>
        <itunes:image href="#{escape("#{base}/podcast/cover.jpg")}"/>
        <generator>earss</generator>
        #{items}
      </channel>
    </rss>
    """
  end

  defp podcast_config do
    cfg = Application.get_env(:earss, :tts, []) |> Keyword.get(:podcast, %{})

    %{
      title: get(cfg, :title, "Earss Listening Queue"),
      description: get(cfg, :description, "Articles saved for listening, synthesized by earss"),
      author: get(cfg, :author, "earss"),
      language: get(cfg, :language, "en-us")
    }
  end

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
