defmodule Earss.FeedScheduler do
  @moduledoc """
  Scheduling math and due-feed selection for global feed crawls.

  See `docs/feed_scheduler_guide.md` and decisions D1 / adaptive policy.
  """

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Feeds.Feed
  alias Earss.Reader.Subscription

  @error_disable_threshold 5
  @max_backoff_factor 32

  @type outcome :: :success_new_content | :success_no_content | :error

  ## Pure scheduling helpers

  @doc """
  Clamp `minutes` into `[min_refresh_interval, max_refresh_interval]`.
  """
  @spec clamp_interval(Feed.t(), number()) :: pos_integer()
  def clamp_interval(%Feed{} = feed, minutes) do
    minutes
    |> trunc()
    |> max(feed.min_refresh_interval)
    |> min(feed.max_refresh_interval)
  end

  @doc """
  Effective interval in minutes (D1).

  Takes the minimum of the feed's current `refresh_interval` and all
  non-hidden subscriptions' `custom_refresh_interval`, then clamps.
  """
  @spec effective_interval(Feed.t(), [integer() | nil] | :load) :: pos_integer()
  def effective_interval(%Feed{} = feed, custom_intervals \\ :load) do
    customs =
      case custom_intervals do
        :load -> load_custom_intervals(feed.id)
        list when is_list(list) -> Enum.filter(list, &is_integer/1)
      end

    candidates = [feed.refresh_interval | customs]
    clamp_interval(feed, Enum.min(candidates))
  end

  @doc """
  Next `refresh_interval` after an outcome (does not apply error backoff to
  the stored interval — only success paths adapt the interval).
  """
  @spec next_refresh_interval(Feed.t(), outcome(), keyword()) :: pos_integer()
  def next_refresh_interval(%Feed{} = feed, outcome, opts \\ []) do
    customs = Keyword.get(opts, :custom_intervals, :load)

    base =
      case outcome do
        :success_new_content ->
          feed.refresh_interval * 0.9

        :success_no_content ->
          feed.refresh_interval * 1.2

        :error ->
          feed.refresh_interval
      end

    # Re-clamp using D1 against customs after adaptation baseline
    feed_for_clamp = %{feed | refresh_interval: max(trunc(base), 1)}
    effective_interval(feed_for_clamp, customs)
  end

  @doc """
  Compute `next_fetch_at` from `now` given outcome and error streak.
  """
  @spec calculate_next_fetch_at(Feed.t(), outcome(), DateTime.t(), keyword()) :: DateTime.t()
  def calculate_next_fetch_at(%Feed{} = feed, outcome, now \\ utc_now(), opts \\ []) do
    customs = Keyword.get(opts, :custom_intervals, :load)
    error_count = Keyword.get(opts, :error_count, feed.error_count)

    interval =
      case outcome do
        :error ->
          # Backoff uses current interval (pre-error), not adapted success interval
          factor = backoff_factor(error_count)
          effective_interval(feed, customs) * factor

        other ->
          next_refresh_interval(feed, other, custom_intervals: customs)
      end

    DateTime.add(now, interval * 60, :second)
  end

  @doc """
  Attributes to merge into a feed after a fetch outcome (interval + next run).
  """
  @spec schedule_attrs(Feed.t(), outcome(), keyword()) :: map()
  def schedule_attrs(%Feed{} = feed, outcome, opts \\ []) do
    now = Keyword.get(opts, :now, utc_now())
    customs = Keyword.get(opts, :custom_intervals, :load)
    error_count = Keyword.get(opts, :error_count, feed.error_count)

    case outcome do
      :error ->
        new_count = error_count + 1

        attrs = %{
          refresh_interval: feed.refresh_interval,
          next_fetch_at:
            calculate_next_fetch_at(feed, :error, now,
              custom_intervals: customs,
              error_count: new_count
            ),
          error_count: new_count
        }

        if new_count >= @error_disable_threshold do
          Map.put(attrs, :is_active, false)
        else
          attrs
        end

      success when success in [:success_new_content, :success_no_content] ->
        new_interval = next_refresh_interval(feed, success, custom_intervals: customs)

        %{
          refresh_interval: new_interval,
          next_fetch_at: DateTime.add(now, new_interval * 60, :second),
          error_count: 0,
          last_error: nil
        }
    end
  end

  def error_disable_threshold, do: @error_disable_threshold

  ## Repo-backed helpers

  @doc """
  Feeds due for crawl, oldest `next_fetch_at` first.

  Requires active feed, due (or nil) next_fetch_at, not unsubscribed, and at
  least one subscription.
  """
  @spec list_due_feeds(pos_integer(), DateTime.t()) :: [Feed.t()]
  def list_due_feeds(limit \\ 50, now \\ utc_now()) when is_integer(limit) and limit > 0 do
    Feed
    |> where([f], f.is_active == true)
    |> where([f], is_nil(f.last_unsubscribed_at))
    |> where([f], is_nil(f.next_fetch_at) or f.next_fetch_at <= ^now)
    |> where(
      [f],
      fragment("exists (select 1 from subscriptions s where s.feed_id = ?)", f.id)
    )
    |> order_by([f], asc_nulls_first: f.next_fetch_at, asc: f.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Set `next_fetch_at` to `now` (default) so the feed is eligible immediately.
  """
  @spec initialize_next_fetch(Feed.t(), DateTime.t()) ::
          {:ok, Feed.t()} | {:error, Ecto.Changeset.t()}
  def initialize_next_fetch(%Feed{} = feed, now \\ utc_now()) do
    feed
    |> Feed.changeset(%{next_fetch_at: now})
    |> Repo.update()
  end

  @doc """
  Load non-hidden custom refresh intervals for a feed (may be empty).
  """
  @spec load_custom_intervals(integer()) :: [pos_integer()]
  def load_custom_intervals(feed_id) do
    Subscription
    |> where([s], s.feed_id == ^feed_id)
    |> where([s], s.is_hidden == false)
    |> where([s], not is_nil(s.custom_refresh_interval))
    |> select([s], s.custom_refresh_interval)
    |> Repo.all()
  end

  defp backoff_factor(error_count) when error_count <= 1, do: 1

  defp backoff_factor(error_count) do
    min(Integer.pow(2, error_count - 1), @max_backoff_factor)
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
