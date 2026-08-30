defmodule Earss.Test.FakeTtsProvider do
  @moduledoc """
  In-memory `Earss.TTS.Provider` for worker tests. Scripted per test via
  the process dictionary (helpers below) — no network, deterministic.
  """

  @behaviour Earss.TTS.Provider

  @audio <<1, 2, 3, 4, 5, 6, 7, 8>>

  ## Test scripting

  def put_script(key, value), do: Process.put({__MODULE__, key}, value)
  def script(key, default \\ nil), do: Process.get({__MODULE__, key}, default)
  def reset, do: Process.delete({__MODULE__, :calls})

  ## Provider callbacks

  @impl true
  def id, do: "fake-tts"

  @impl true
  def adapter_api, do: Earss.TTS.Provider.api_version()

  @impl true
  def provider_info, do: %{name: "Fake TTS"}

  @impl true
  def synthesize(params, _opts) do
    record_call({:synthesize, params})

    case script(:synthesize) do
      :fail -> {:error, :scripted_failure}
      _ -> {:ok, %{audio: @audio, content_type: "audio/mpeg", meta: %{}}}
    end
  end

  @impl true
  def submit(params, _opts) do
    record_call({:submit, params})

    case script(:submit) do
      :fail -> {:error, :scripted_failure}
      _ -> {:ok, %{job_id: "fake-job-1"}}
    end
  end

  @impl true
  def poll(_job_id, _opts) do
    polls = script(:polls_remaining, 1)
    put_script(:polls_remaining, max(polls - 1, 0))

    cond do
      script(:poll) == :fail -> {:error, :scripted_failure}
      polls > 0 -> {:ok, :processing, %{}}
      true -> {:ok, :ready, %{}}
    end
  end

  @impl true
  def download(_job_id, _opts) do
    record_call({:download, %{}})

    case script(:download) do
      :fail -> {:error, :scripted_failure}
      _ -> {:ok, %{audio: @audio, content_type: "audio/mpeg", meta: %{}}}
    end
  end

  defp record_call(call) do
    Process.put({__MODULE__, :calls}, [call | script(:calls, [])])
  end

  def calls, do: Enum.reverse(script(:calls, []))
end
