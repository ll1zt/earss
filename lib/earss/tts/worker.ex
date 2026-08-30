defmodule Earss.TTS.Worker do
  @moduledoc """
  Consumes `requested` `tts_requests` rows and produces audio.

  Tick loop (like `Earss.Enrichment.PendingWorker`):

    1. skip silently when no provider is registered (rows stay `requested`;
       the next tick re-checks, so a late-loading plugin picks the backlog
       up without operator action)
    2. requeue rows stuck in `processing` whose lease expired (crashed node,
       killed task), counting the lease expiry as an attempt so a
       permanently failing entry still settles in `failed`
    3. claim a batch of due rows (`requested`, `retry_at` passed), marking
       them `processing`
    4. process each claim in a supervised task: entry → readable text,
       script detection, provider call (sync for short text, async jobs for
       long text), audio written to `:audio_dir/<entry_id>.<ext>`,
       row → `ready`
    5. failures increment `attempt_count` and back off exponentially; past
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
       max_chars_sync: 100_000, processing_lease_secs: 1_800]`

  Note: `await_job/3` polls provider async jobs inside a held `Limiter`
  slot, so an in-flight async job serialises all synthesis while
  `max_concurrency` slots are occupied.
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
    # `processing` until restart. Recovery second: rows whose processing
    # lease expired must re-enter the queue before the claim below selects.
    case pick_provider() do
      {:ok, provider} ->
        recover_stuck(state.worker_cfg)

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

  # A request left in `processing` (crashed node, killed task, restart) has no
  # owner any more — without recovery it would never be retried. Requeue rows
  # whose lease expired. The lease expiry counts as an attempt: rows that
  # still have retries left re-enter the queue (with a fresh `retry_at`, so
  # the backoff schedule keeps applying); rows past the limit settle in
  # `failed` instead of looping forever.
  @spec recover_stuck(map()) :: non_neg_integer()
  def recover_stuck(worker_cfg) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    cutoff =
      now
      |> DateTime.add(-worker_cfg.processing_lease_secs, :second)
      |> DateTime.truncate(:second)

    # Requeue the rows that still have attempts left…
    {requeued, _} =
      Request
      |> where([r], r.state == :processing and r.updated_at <= ^cutoff)
      |> where([r], r.attempt_count < ^worker_cfg.max_retries)
      |> Repo.update_all(
        set: [
          state: "requested",
          error: "processing lease expired — requeued",
          retry_at: now,
          updated_at: now
        ],
        inc: [attempt_count: 1]
      )

    # …and give up on the rest so they cannot loop forever.
    {failed, _} =
      Request
      |> where([r], r.state == :processing and r.updated_at <= ^cutoff)
      |> where([r], r.attempt_count >= ^worker_cfg.max_retries)
      |> Repo.update_all(
        set: [
          state: "failed",
          error: "processing lease expired — gave up after max retries",
          updated_at: now
        ]
      )

    if failed > 0 do
      Logger.warning(
        "Earss.TTS.Worker: #{failed} processing lease(s) expired past max retries — marked failed"
      )
    end

    requeued + failed
  end

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

  # Audio is written to a temp file and renamed into place so the podcast
  # endpoint can never observe a half-written file: it either sees the
  # complete file at its final name or nothing at all.
  #
  # The row is marked `ready` only after the rename succeeds. If the DB
  # update fails instead, the file is removed right away — otherwise it
  # would linger as an orphan for the Level E sweep (24h grace) to collect.
  defp store_audio(request, provider, %{audio: audio, content_type: content_type}, opts) do
    audio_dir = audio_dir!(opts)
    ext = extension_for(content_type)
    filename = "#{request.entry_id}.#{ext}"
    path = Path.join(audio_dir, filename)
    tmp = Path.join(audio_dir, ".#{filename}.#{System.unique_integer([:positive])}.part")

    try do
      File.write!(tmp, audio)
      File.rename!(tmp, path)

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
    after
      # Clean up whatever reached the filesystem. Runs even when `fail/4`
      # itself raises (row deleted underneath us, lost DB connection)
      # because a file no row points at is worse than no file: nothing can
      # serve it, and it lingers until the Level E orphan sweep (24h grace)
      # collects it. The next attempt re-synthesizes from scratch.
      _ = File.rm(tmp)

      unless Repo.get(Request, request.id) |> ready_audio_path?() do
        _ = File.rm(path)
      end

      :ok
    end
  end

  defp ready_audio_path?(%{state: :ready, audio_path: p}) when is_binary(p), do: true
  defp ready_audio_path?(_), do: false

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

  # Recording a failure is the last line of defence before a row is lost
  # track of, so it must not be able to fail silently: a bare rescue would
  # hide a broken row from the operator with nothing in the logs. Log the
  # reason and move on — the tick loop keeps running either way.
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
    e ->
      Logger.error(
        "TTS: could not record failure for entry #{request.entry_id}: " <>
          Exception.message(e)
      )

      :ok
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
      max_chars_sync: Keyword.get(opts, :max_chars_sync, 100_000),
      # How long a claimed row may stay in `processing` before it is
      # considered orphaned and requeued. Must exceed the longest expected
      # provider call (long articles on slow free tiers can take minutes).
      processing_lease_secs: Keyword.get(opts, :processing_lease_secs, 1_800)
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
