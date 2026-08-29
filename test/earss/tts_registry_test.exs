defmodule Earss.TtsRegistryTest do
  # async: false — registration state is global ETS under a named server.
  use ExUnit.Case, async: false

  alias Earss.TTS.{Provider, Registry}

  defmodule GoodProvider do
    @behaviour Provider

    @impl true
    def id, do: "test-tts"

    @impl true
    def adapter_api, do: Provider.api_version()

    @impl true
    def provider_info, do: %{name: "Test TTS"}

    @impl true
    def synthesize(_params, _opts), do: {:error, :not_implemented}
  end

  defmodule WrongApiProvider do
    def id, do: "wrong-api"
    def adapter_api, do: 99
    def synthesize(_params, _opts), do: {:ok, %{}}
  end

  defmodule MissingCallbacksProvider do
    def id, do: "missing-callbacks"
  end

  setup do
    Registry.unregister("test-tts")
    Registry.unregister("wrong-api")

    on_exit(fn ->
      Registry.unregister("test-tts")
      Registry.unregister("wrong-api")
    end)

    :ok
  end

  test "registers and fetches a conforming provider" do
    assert :ok = Registry.register(%{module: GoodProvider})

    assert {:ok, GoodProvider} = Registry.fetch("test-tts")

    assert %{id: "test-tts", module: GoodProvider} =
             Enum.find(Registry.list_providers(), &(&1.id == "test-tts"))
  end

  test "duplicate id is rejected" do
    assert :ok = Registry.register(%{module: GoodProvider})
    assert {:error, :already_registered} = Registry.register(%{module: GoodProvider})
  end

  test "module with wrong adapter_api is rejected" do
    assert {:error, {:unsupported_adapter_api, 99, 1}} =
             Registry.register(%{module: WrongApiProvider})
  end

  test "module missing required callbacks is rejected" do
    assert {:error, :not_a_provider} = Registry.register(%{module: MissingCallbacksProvider})
  end

  test "id is inferred from the module when omitted" do
    assert :ok = Registry.register(%{module: GoodProvider, version: "0.2.0"})
    assert {:ok, GoodProvider} = Registry.fetch("test-tts")
  end
end

defmodule Earss.TtsLimiterTest do
  # async: false — the named gate holds global state.
  use ExUnit.Case, async: false

  alias Earss.TTS.Limiter

  setup do
    Application.put_env(:earss, :tts, max_concurrency: 1, listen_controls: false, public_url: nil)
    on_exit(fn -> Application.delete_env(:earss, :tts) end)

    case Limiter.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "second acquire waits until the first is released (FIFO)" do
    assert Limiter.acquire() == :ok

    waiter = Task.async(fn -> Limiter.acquire() end)
    refute Task.yield(waiter, 0), "second acquire must wait for a slot"

    Limiter.release()
    assert Task.await(waiter, 1000) == :ok

    Limiter.release()
    # everything released: a fresh acquire succeeds immediately
    assert Limiter.acquire() == :ok
    Limiter.release()
  end

  test "stray release from a non-holder is ignored" do
    assert Limiter.release() == :ok
    assert Limiter.acquire() == :ok
    Limiter.release()
  end
end
