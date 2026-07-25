defmodule Earss.Reader do
  @moduledoc """
  The Reader context facade.

  Users, categories, subscriptions, reading state, and per-user timelines.
  Lifecycle side effects follow `docs/data_lifecycle.md`.

  Implementation is split across `Earss.Reader.Users`, `Categories`,
  `Subscriptions`, `EntryStates`, `Timeline`, `OPMLImport`, and
  `Earss.Fever.Queries`. This module keeps a stable public API via
  `defdelegate` / thin wrappers.
  """

  alias Earss.Reader.Users
  alias Earss.Reader.Categories
  alias Earss.Reader.Subscriptions
  alias Earss.Reader.EntryStates
  alias Earss.Reader.Timeline
  alias Earss.Reader.OPMLImport
  alias Earss.Fever.Queries, as: FeverQueries

  ## Users

  defdelegate create_sub_user(username, password), to: Users

  def create_user(username, password, user_type \\ "admin"),
    do: Users.create_user(username, password, user_type)

  defdelegate get_user(id), to: Users
  defdelegate get_user_by_username(username), to: Users
  defdelegate get_user_by_fever_api_key(api_key), to: Users
  defdelegate authenticate_user(username, password), to: Users
  defdelegate set_password(user, password), to: Users
  defdelegate set_fever_password(user, secret), to: Users
  defdelegate fever_api_key(username, secret), to: Users
  defdelegate deactivate_user(user), to: Users
  defdelegate delete_user(username, password), to: Users
  defdelegate delete_user(admin_username, admin_password, sub_user_username), to: Users

  ## Categories

  defdelegate list_categories(user), to: Categories
  defdelegate get_category(id), to: Categories
  defdelegate create_category(user, attrs), to: Categories
  defdelegate update_category(category, attrs), to: Categories
  defdelegate delete_category(category), to: Categories

  ## Subscriptions

  defdelegate subscribe(user, attrs), to: Subscriptions
  defdelegate unsubscribe(user, feed_id), to: Subscriptions
  defdelegate get_subscription(user, feed_id), to: Subscriptions

  def list_subscriptions(user, opts \\ []),
    do: Subscriptions.list_subscriptions(user, opts)

  defdelegate unread_counts_by_feed(user), to: Subscriptions
  defdelegate update_subscription(subscription, attrs), to: Subscriptions
  defdelegate hide_subscription(subscription), to: Subscriptions
  defdelegate unhide_subscription(subscription), to: Subscriptions

  ## Entry states (lazy)

  defdelegate mark_read(user, entry_id), to: EntryStates
  defdelegate mark_unread(user, entry_id), to: EntryStates
  defdelegate set_star(user, entry_id, starred?), to: EntryStates
  defdelegate get_entry_state(user, entry_id), to: EntryStates
  defdelegate mark_entries_read(user, opts), to: EntryStates

  ## OPML

  def import_opml(user, xml, opts \\ []), do: OPMLImport.import_opml(user, xml, opts)
  def export_opml(user, opts \\ []), do: OPMLImport.export_opml(user, opts)

  ## Fever helpers (Earss.Fever.Queries — D2)

  def list_unread_entry_ids(user, opts \\ []), do: FeverQueries.list_unread_entry_ids(user, opts)
  def list_starred_entry_ids(user, opts \\ []), do: FeverQueries.list_starred_entry_ids(user, opts)
  defdelegate count_fever_items(user), to: FeverQueries
  def list_fever_items(user, opts \\ []), do: FeverQueries.list_fever_items(user, opts)

  ## Timeline

  def list_entries(user, opts \\ []), do: Timeline.list_entries(user, opts)
end
