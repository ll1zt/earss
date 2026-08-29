defmodule Earss.TtsLinkTest do
  # async: false — these tests mutate the global :earss, :tts application
  # env, which other listen-control tests read.
  use ExUnit.Case, async: false

  alias Earss.TTS.Link

  @id 123

  setup do
    # test.exs sets secret_key_base; tests here only need :tts present.
    Application.put_env(:earss, :tts,
      listen_controls: true,
      public_url: "https://earss.example.net"
    )

    on_exit(fn -> Application.delete_env(:earss, :tts) end)
    :ok
  end

  describe "sign/1 and verify/1" do
    test "roundtrip recovers the entry id" do
      assert {:ok, @id} = Link.verify(Link.sign(@id))
    end

    test "tampered token is rejected" do
      [msg, sig] = String.split(Link.sign(@id), ".", parts: 2)

      assert :error = Link.verify("#{msg}.A#{sig}")
      assert :error = Link.verify("garbage")
      assert :error = Link.verify("")
    end

    test "tokens from a different salt are rejected" do
      api_token =
        Plug.Crypto.sign(
          Application.fetch_env!(:earss, :api)[:secret_key_base],
          "earss.api.auth",
          %{operator: "earss"}
        )

      assert :error = Link.verify(api_token)
    end
  end

  describe "url/1" do
    test "builds an absolute endpoint URL with the signature as query param" do
      assert url = Link.url(@id)
      assert String.starts_with?(url, "https://earss.example.net/tts/listen/#{@id}?sig=")
    end

    test "trailing slash in public_url does not double up" do
      Application.put_env(:earss, :tts,
        listen_controls: true,
        public_url: "http://localhost:4000/"
      )

      assert %URI{path: "/tts/listen/" <> _} = URI.parse(Link.url(@id))
    end

    test "returns nil when the feature flag is off" do
      Application.put_env(:earss, :tts,
        listen_controls: false,
        public_url: "https://earss.example.net"
      )

      assert Link.url(@id) == nil
    end

    test "returns nil when no public_url and no base given" do
      Application.put_env(:earss, :tts, listen_controls: true, public_url: nil)

      assert Link.url(@id) == nil
    end

    test "url/2 accepts a request-derived base without public_url configured" do
      Application.put_env(:earss, :tts, listen_controls: true, public_url: nil)

      url = Link.url(@id, "http://192.168.9.101:4000")
      assert String.starts_with?(url, "http://192.168.9.101:4000/tts/listen/#{@id}?sig=")
    end

    test "configured public_url wins over a request-derived base" do
      url = Link.url(@id, "http://192.168.9.101:4000")
      assert String.starts_with?(url, "https://earss.example.net/tts/listen/#{@id}?sig=")
    end

    test "url/2 still nil when the feature flag is off" do
      Application.put_env(:earss, :tts, listen_controls: false, public_url: nil)

      assert Link.url(@id, "http://localhost:4000") == nil
    end
  end
end
