defmodule Earss.ListenControlsTest do
  use Earss.ConnCase

  alias Earss.API.ListenControls
  alias Earss.Feeds
  alias Earss.Fever
  alias Earss.GReader.Ids
  alias Earss.Reader
  alias Earss.Repo
  alias Earss.TTS.Link

  @id 42

  setup do
    Application.put_env(:earss, :tts,
      listen_controls: true,
      public_url: "https://earss.example.net"
    )

    on_exit(fn -> Application.delete_env(:earss, :tts) end)
    :ok
  end

  describe "decorate/2" do
    test "prepends the control carrying the signed URL before the content" do
      decorated = ListenControls.decorate("<p>body</p>", @id)

      # Control leads, original content follows verbatim.
      assert String.starts_with?(decorated, "<hr")
      assert String.ends_with?(decorated, "<p>body</p>")
      assert decorated =~ ~s(/tts/listen/#{@id}?sig=)
      assert decorated =~ ~s(target="_blank")
      assert decorated =~ ~s(>🎧 Listen</a></p>)
    end

    test "nil content becomes just the control (title-only articles listen too)" do
      decorated = ListenControls.decorate(nil, @id)

      assert String.starts_with?(decorated, "<hr class=\"earss-listen\">")
      assert String.ends_with?(decorated, "🎧 Listen</a></p>")
      assert decorated =~ "/tts/listen/#{@id}?sig="
    end

    test "static parts are identical across calls (only the random nonce differs)" do
      d1 = ListenControls.decorate("<p>x</p>", @id)
      d2 = ListenControls.decorate("<p>x</p>", @id)

      # Everything up to the sig (prefix + href) matches; the sig itself is
      # randomised per call by Plug.Crypto.
      [h1, _] = String.split(d1, "sig=")
      [h2, _] = String.split(d2, "sig=")
      assert h1 == h2
    end

    test "passes content through unchanged when disabled" do
      Application.put_env(:earss, :tts, listen_controls: false, public_url: nil)

      assert ListenControls.decorate("<p>body</p>", @id) == "<p>body</p>"
      assert ListenControls.decorate(nil, @id) == nil
    end
  end

  describe "request_base/1" do
    setup do
      # No public_url override: the base must come from the request itself.
      Application.put_env(:earss, :tts, listen_controls: true, public_url: nil)
      :ok
    end

    test "derives scheme/host from the reader request (default ports omitted)" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:scheme, :http)
        |> Map.put(:host, "192.168.9.101")
        |> Map.put(:port, 4000)

      assert ListenControls.request_base(conn) == "http://192.168.9.101:4000"
    end

    test "omits the port when it is the scheme default" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:scheme, :https)
        |> Map.put(:host, "earss.example.net")
        |> Map.put(:port, 443)

      assert ListenControls.request_base(conn) == "https://earss.example.net"
    end

    test "configured public_url wins over the request" do
      Application.put_env(:earss, :tts,
        listen_controls: true,
        public_url: "https://earss.example.net"
      )

      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:scheme, :http)
        |> Map.put(:host, "localhost")
        |> Map.put(:port, 4000)

      assert ListenControls.request_base(conn) == "https://earss.example.net"
    end
  end

  describe "protocol view integration (feature enabled)" do
    setup do
      {:ok, feed} = Feeds.create_feed(%{link: "https://example.com/listen_ctrl.xml"})

      {:ok, entry} =
        Feeds.upsert_entry(feed, %{
          link: "https://example.com/article",
          guid: "listen-ctrl-article",
          title: "Article",
          content: "<p>Hello</p>"
        })

      {:ok, _} = Reader.subscribe(%{feed_id: feed.id, refresh: false})
      %{entry_id: entry.id}
    end

    test "GReader item contents carry the control", %{entry_id: entry_id} do
      [item] = Earss.GReader.items_contents([Ids.item_atom_id(entry_id)])["items"]

      content = item["summary"]["content"]
      assert content =~ "earss-listen-link"
      assert content =~ "/tts/listen/#{entry_id}?sig="
    end

    test "Fever item html carries the control", %{entry_id: entry_id} do
      resp = Fever.handle(%{"api_key" => "test-fever-key", "items" => "", "since_id" => "0"})
      item = Enum.find(resp["items"], &(&1["id"] == entry_id))

      assert item != nil
      assert item["html"] =~ "earss-listen-link"
      assert item["html"] =~ "/tts/listen/#{entry_id}?sig="
    end

    test "JSON API entry rows carry the control pointing at the request host; stored content stays untouched",
         %{
           entry_id: entry_id
         } do
      # Drop the public_url override so the base comes from the request.
      Application.put_env(:earss, :tts, listen_controls: true, public_url: nil)

      token = login_token()
      conn = json_req(:get, "/api/entries", nil, auth_header(token))

      assert conn.status == 200
      entry = Enum.find(Jason.decode!(conn.resp_body)["entries"], &(&1["id"] == entry_id))
      assert entry != nil
      assert entry["content"] =~ "earss-listen-link"

      # conn_case pins host to www.example.com — the link reuses the
      # reader's own request address when public_url is not configured.
      assert entry["content"] =~ "http://www.example.com/tts/listen/#{entry_id}?sig="

      # The shared entry row is never mutated — injection is render-time only.
      refute Repo.get(Feeds.Entry, entry_id).content =~ "earss-listen"
    end
  end
end
