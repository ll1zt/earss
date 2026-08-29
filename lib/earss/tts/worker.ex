defmodule Earss.TTS.Worker do
  @moduledoc """
  Consumes `requested` `tts_requests` rows and produces audio.

  Tick loop (like `Earss.Enrichment.PendingWorker`):

    1. skip silently when no provider is registered (rows stay `requested`;
       the next tick re-checks, so a late-loading plugin picks the backlog
       up without operator action)
    2. claim a batch of due rows (`requested`, `retry_at` passed), marking
       them `processing`
    3. process each claim in a supervised task: entry → readable text,
       script detection, provider call (sync for short text, async jobs for
       long text), audio written to `:audio_dir/<entry_id>.<ext>`,
       row → `ready`
    4. failures increment `attempt_count` and back off exponentially; past
       `max_retries` the row settles in `failed`

  Provider calls are bounded by `Earss.TTS.Limiter`; a crash inside a task
  releases the slot automatically (leak-proof gate). Path selection: the
  host uses the synchronous `synthesize/2` up to `max_chars_sync` chars and
  the async `submit/poll/download` path beyond — keep `max_chars_sync`
  aligned with your provider's own synchronous limit.

  Configuration (`config :earss, :tts`):

    * `:audio_dir` — required to store audio; without it the worker idles
    * `:provider_opts` — opaque keyword passed verbatim to provider calls
      (tests inject a Bypass URL this way; providers also read their own env)
    * `:worker` — `[enabled: false, interval_ms: 30_000, batch_size: 5,
       max_retries: 5, poll_interval_ms: 2_000, poll_attempts: 60,
       max_chars_sync: 2500]`
  """

  use GenServer, restart: :transient

  require Logger

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.TTS.{Audio, Lang, Limiter, Registry, Request, Text}
  alias Earss.TTS.TaskSupervisor

  # —— public API ——

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Process one request synchronously (used by tests and operator retries).
  Never raises: every failure path lands as a row update.
  """
  @spec process_job(Request.t(), provider :: module(), keyword()) :: :ok
  def process_job(%Request{} = request, provider, opts \\ []) do
    request = Repo.preload(request, :entry)
    worker_cfg = worker_cfg_from(opts)

    with {:ok, text} <- extract_text(request.entry),
         {:ok, audio} <- synthesize(provider, text, worker_cfg) do
      store_audio(request, provider, audio, opts)
    else
      {:error, reason} -> fail(request, provider, reason, worker_cfg)
      :no_text -> fail(request, provider, :no_readable_text, worker_cfg)
    end

    :ok
  rescue
    e ->
      fail(request, provider, Exception.message(e), worker_cfg_from(opts))
      :ok
  end

  # —— GenServer ——

  @impl true
  def init(opts) do
    cfg = worker_config(Keyword.get(opts, :worker, []))
    audio_dir = Keyword.get(opts, :audio_dir)

    enabled? = cfg.enabled and is_binary(audio_dir)

    unless enabled? do
      Logger.info(
        "Earss.TTS.Worker idle (worker enabled: #{cfg.enabled}, audio_dir set: #{is_binary(audio_dir)})"
      )
    end

    state = %{
      enabled: enabled?,
      interval_ms: cfg.interval_ms,
      audio_dir: audio_dir,
      worker_cfg: cfg
    }

    Process.send_after(self(), :tick, 1_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{enabled: true} = state) do
    # Provider first: claiming rows without a provider would strand them in
    # `processing` until restart.
    case pick_provider() do
      {:ok, provider} ->
        case claim(state.worker_cfg) do
          requests when is_list(requests) ->
            Enum.each(requests, fn request ->
              Task.Supervisor.start_child(TaskSupervisor, fn ->
                process_job(request, provider,
                  audio_dir: state.audio_dir,
                  worker: Map.to_list(state.worker_cfg)
                )
              end)
            end)

          :error ->
            :ok
        end

      :error ->
        :ok
    end

    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # —— claims ——

  # Boundary isolation, not control flow: a database hiccup (restart,
  # dropped connection) must not take the worker — and with it the whole
  # supervision tree — down. Log and retry on the next tick.
  defp claim(worker_cfg) do
    claim_batch(worker_cfg)
  rescue
    e ->
      Logger.warning(
        "Earss.TTS.Worker: claim failed, retrying next tick: #{Exception.message(e)}"
      )

      :error
  end

  defp claim_batch(worker_cfg) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ids =
      Request
      |> where([r], r.state == :requested)
      |> where([r], is_nil(r.retry_at) or r.retry_at <= ^now)
      |> order_by(asc: :id)
      |> limit(^worker_cfg.batch_size)
      |> select([r], r.id)
      |> Repo.all()

    if ids == [] do
      []
    else
      {_count, _} =
        Request
        |> where([r], r.id in ^ids and r.state == :requested)
        |> Repo.update_all(set: [state: "processing", updated_at: now])

      # Re-read the claimed rows (update_all returning is unreliable across
      # ecto versions); a row re-claimed by nobody else — only this worker
      # flips requested→processing — so the re-read is race-free.
      Request
      |> where([r], r.id in ^ids and r.state == :processing)
      |> Repo.all()
    end
  end

  defp pick_provider do
    case Registry.list_providers() do
      [%{module: mod} | _] -> {:ok, mod}
      [] -> :error
    end
  end

  # —— synthesis ——

  defp extract_text(entry) do
    Text.from_entry(entry)
  end

  defp synthesize(provider, text, worker_cfg) do
    params = %{
      text: text,
      lang: lang_tag(Lang.script(text)),
      voice_key: nil,
      format: "mp3"
    }

    Limiter.acquire()

    try do
      if String.length(text) <= worker_cfg.max_chars_sync do
        sync_call(provider, params)
      else
        async_call(provider, params, worker_cfg)
      end
    after
      Limiter.release()
    end
  end

  defp sync_call(provider, params) do
    provider.synthesize(params, provider_opts())
  end

  # Long text: submit → poll until ready → download. Requires the provider
  # to implement the optional async half of the contract.
  defp async_call(provider, params, worker_cfg) do
    if function_exported?(provider, :submit, 2) do
      with {:ok, %{job_id: job_id}} <- provider.submit(params, provider_opts()) do
        await_job(provider, job_id, worker_cfg)
      end
    else
      {:error, :async_unsupported}
    end
  end

  defp await_job(provider, job_id, worker_cfg) do
    case provider.poll(job_id, provider_opts()) do
      {:ok, :ready, _meta} ->
        provider.download(job_id, provider_opts())

      {:ok, :failed, meta} ->
        {:error, {:provider_job_failed, meta}}

      {:ok, status, _meta} when status in [:pending, :processing] ->
        if worker_cfg.poll_attempts <= 0 do
          {:error, :provider_job_timeout}
        else
          Process.sleep(worker_cfg.poll_interval_ms)
          await_job(provider, job_id, %{worker_cfg | poll_attempts: worker_cfg.poll_attempts - 1})
        end

      {:error, _} = err ->
        err
    end
  end

  # Script family → provider language tag. Providers map the tag onto their
  # own voice selection (e.g. EARSS_TTS_PODCAST_VOICE_ZH).
  defp lang_tag(:zh), do: "zh"
  defp lang_tag(:ja), do: "ja"
  defp lang_tag(:ko), do: "ko"
  defp lang_tag(:latin), do: "en"
  defp lang_tag(_), do: nil

  # provider knobs (api key, base url, model…) travel in opts; the host does
  # not interpret them.
  defp provider_opts do
    :earss |> Application.get_env(:tts, []) |> Keyword.get(:provider_opts, [])
  end

  # —— storage ——

  defp store_audio(request, provider, %{audio: audio, content_type: content_type}, opts) do
    audio_dir = audio_dir!(opts)
    ext = extension_for(content_type)
    filename = "#{request.entry_id}.#{ext}"
    path = Path.join(audio_dir, filename)

    File.write!(path, audio)

    request
    |> Ecto.Changeset.change(
      state: :ready,
      provider: provider.id(),
      audio_path: filename,
      audio_bytes: byte_size(audio),
      audio_duration_secs: Audio.estimate_duration_secs(byte_size(audio), ext),
      error: nil
    )
    |> Repo.update!()

    :ok
  rescue
    e ->
      fail(request, provider, Exception.message(e), worker_cfg_from(opts))
      :ok
  end

  defp extension_for(content_type) do
    case content_type do
      "audio/mpeg" -> "mp3"
      "audio/mp4" -> "m4a"
      "audio/aac" -> "aac"
      "audio/wav" -> "wav"
      "audio/ogg" -> "ogg"
      "audio/flac" -> "flac"
      _ -> "bin"
    end
  end

  # —— failure bookkeeping ——

  defp fail(request, _provider, reason, worker_cfg) do
    attempt = (request.attempt_count || 0) + 1

    Logger.warning(
      "TTS synthesis failed for entry #{request.entry_id} " <>
        "(attempt #{attempt}/#{worker_cfg.max_retries}): #{inspect(reason)}"
    )

    request
    |> Request.failure_changeset(%{
      attempt_count: attempt,
      max_retries: worker_cfg.max_retries,
      backoff_secs: backoff_secs(attempt),
      error: reason
    })
    |> Repo.update!()

    :ok
  rescue
    _ -> :ok
  end

  defp backoff_secs(1), do: 30
  defp backoff_secs(2), do: 120
  defp backoff_secs(attempt), do: 300 * attempt

  # —— config ——

  defp worker_cfg_from(opts), do: worker_config(Keyword.get(opts, :worker, []))

  defp worker_config(opts) when is_list(opts) do
    %{
      enabled: Keyword.get(opts, :enabled, false),
      interval_ms: Keyword.get(opts, :interval_ms, 30_000),
      batch_size: Keyword.get(opts, :batch_size, 5),
      max_retries: Keyword.get(opts, :max_retries, 5),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 2_000),
      poll_attempts: Keyword.get(opts, :poll_attempts, 60),
      max_chars_sync: Keyword.get(opts, :max_chars_sync, 2_500)
    }
  end

  defp audio_dir!(opts) do
    case Keyword.get(opts, :audio_dir) do
      dir when is_binary(dir) ->
        File.mkdir_p!(dir)
        dir

      nil ->
        raise "config :earss, :tts, audio_dir is not set"
    end
  end
end
