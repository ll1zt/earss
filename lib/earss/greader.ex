defmodule Earss.GReader do
  @moduledoc """
  Google Reader API subset used by FreshRSS-compatible clients (e.g. NetNewsWire).

  See `docs/greader.md`.

  Implementation is split across `Earss.GReader.Auth`, `Ids`, `Streams`,
  `Items`, and `Subscriptions`. This module remains the stable facade.
  All operations act on the single operator (docs/single_user.md).
  """

  alias Earss.GReader.Auth
  alias Earss.GReader.Ids
  alias Earss.GReader.Streams
  alias Earss.GReader.Items
  alias Earss.GReader.Subscriptions

  ## Auth

  defdelegate issue_auth(), to: Auth
  defdelegate verify_auth(token), to: Auth
  defdelegate issue_edit_token(), to: Auth
  defdelegate verify_edit_token(user, token), to: Auth
  defdelegate client_login(email, password), to: Auth

  ## IDs

  defdelegate feed_stream_id(feed), to: Ids
  defdelegate label_stream_id(name), to: Ids
  defdelegate item_hex_id(id), to: Ids
  defdelegate item_atom_id(id), to: Ids
  defdelegate parse_item_id(id), to: Ids
  defdelegate normalize_stream_id(stream_id), to: Ids

  ## Catalog / subscriptions

  defdelegate subscription_list(), to: Subscriptions
  defdelegate tag_list(), to: Subscriptions
  defdelegate user_info(), to: Subscriptions
  defdelegate unread_count(), to: Subscriptions
  defdelegate subscription_edit(params), to: Subscriptions

  ## Streams

  def stream_item_ids(stream_id, opts \\ []),
    do: Streams.stream_item_ids(stream_id, opts)

  def stream_contents(stream_id, opts \\ []),
    do: Streams.stream_contents(stream_id, opts)

  ## Items / tags

  defdelegate items_contents(item_ids, opts \\ []), to: Items
  defdelegate edit_tag(item_ids, add, remove), to: Items

  def mark_all_as_read(stream_id, timestamp_sec \\ nil),
    do: Items.mark_all_as_read(stream_id, timestamp_sec)
end
