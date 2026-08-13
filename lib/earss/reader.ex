defmodule Earss.Reader do
  @moduledoc """
  The Reader context facade.

  Categories, subscriptions, reading state, and the operator's timeline —
  all scoped to the single operator (see docs/single_user.md). During the
  single-user transition the underlying rows still carry a `user_id` pinned
  to `Earss.Reader.AnchorUser.id/0`; the db-schema-v2 migration drops the
  column entirely.

  Lifecycle side effects follow `docs/data_lifecycle.md`.

  Implementation is split across `Earss.Reader.Categories`, `Subscriptions`,
  `EntryStates`, `Timeline`, `OPMLImport`, and `Earss.Fever.Queries`. This
  module keeps a stable public API via `defdelegate` / thin wrappers.
  """

  alias Earss.Reader.Categories
  alias Earss.Reader.Subscriptions
  alias Earss.Reader.EntryStates
  alias Earss.Reader.Timeline
  alias Earss.Reader.OPMLImport
  alias Earss.Fever.Queries, as: FeverQueries

  ## Categories

  defdelegate list_categories(), to: Categories
  defdelegate get_category(id), to: Categories
  defdelegate create_category(attrs), to: Categories
  defdelegate update_category(category, attrs), to: Categories
  defdelegate delete_category(category), to: Categories

  ## Subscriptions

  defdelegate subscribe(attrs), to: Subscriptions
  defdelegate unsubscribe(feed_id), to: Subscriptions
  defdelegate get_subscription(feed_id), to: Subscriptions

  def list_subscriptions(opts \\ []),
    do: Subscriptions.list_subscriptions(opts)

  defdelegate unread_counts_by_feed(), to: Subscriptions
  defdelegate update_subscription(subscription, attrs), to: Subscriptions
  defdelegate hide_subscription(subscription), to: Subscriptions
  defdelegate unhide_subscription(subscription), to: Subscriptions

  ## Entry states (lazy)

  defdelegate mark_read(entry_id), to: EntryStates
  defdelegate mark_unread(entry_id), to: EntryStates
  defdelegate set_star(entry_id, starred?), to: EntryStates
  defdelegate get_entry_state(entry_id), to: EntryStates
  defdelegate mark_entries_read(opts), to: EntryStates

  ## OPML

  def import_opml(xml, opts \\ []), do: OPMLImport.import_opml(xml, opts)
  def export_opml(opts \\ []), do: OPMLImport.export_opml(opts)

  ## Fever helpers (Earss.Fever.Queries — D2)

  def list_unread_entry_ids(opts \\ []), do: FeverQueries.list_unread_entry_ids(opts)
  def list_starred_entry_ids(opts \\ []), do: FeverQueries.list_starred_entry_ids(opts)
  defdelegate count_fever_items(), to: FeverQueries
  def list_fever_items(opts \\ []), do: FeverQueries.list_fever_items(opts)

  ## Timeline

  def list_entries(opts \\ []), do: Timeline.list_entries(opts)
end
