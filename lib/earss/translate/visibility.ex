defmodule Earss.Translate.Visibility do
  @moduledoc """
  Translation-window hiding (Goal 2).

  Entries of feeds with a translation target are **not exposed to protocol
  clients until their translation exists** (or the window expires). NetNewsWire
  only re-fetches articles that are missing locally, so an untranslated entry
  seen during the window would be cached as original text forever.

  Window semantics:

    * entry is hidden while: a target language exists (subscription override →
      feed setting), no stored translation for that language, and
      `inserted_at` is within the window (default 15 minutes,
      `:visibility_window_minutes` in `config :earss, :translate`)
    * when the window expires without a translation (e.g. provider errors) the
      entry becomes visible again with the original text — nothing is ever lost

  The predicate is applied at the query layer (GReader streams/items/unread
  counts, Fever, JSON timeline) so every protocol surface stays consistent.
  """

  @default_window_minutes 15

  @doc "Hiding window in minutes (config override supported)."
  @spec window_minutes() :: pos_integer()
  def window_minutes do
    :earss
    |> Application.get_env(:translate, [])
    |> Keyword.get(:visibility_window_minutes, @default_window_minutes)
  end

  @pending_sql """
  coalesce(?, ?) IS NOT NULL
    AND ? > (now() AT TIME ZONE 'UTC') - (? * interval '1 minute')
    AND NOT EXISTS (
      SELECT 1 FROM entry_translations t
      WHERE t.entry_id = ? AND t.lang = coalesce(?, ?)
    )
  """

  @doc """
  SQL fragment selecting entries that are pending translation and still
  inside the hiding window (to be used inside `not fragment(...)`).

  Placeholder order: subscription `translate_to`, feed `translate_to`,
  `entry.inserted_at`, window minutes, `entry.id`, then the same subscription
  and feed language values again for the `EXISTS` subquery.
  """
  @spec pending_sql() :: String.t()
  def pending_sql do
    @pending_sql
  end
end
