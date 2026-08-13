defmodule Earss.Admin.ControllerHelpers do
  @moduledoc false

  alias Earss.Admin.Auth
  alias Earss.Admin.Helpers
  alias Earss.Reader
  alias Earss.Reader.{Category, Subscription}
  alias Earss.Repo

  def with_user(conn, fun) do
    conn = Auth.require_user(conn, [])
    if conn.halted, do: conn, else: fun.(conn)
  end

  def owned_sub(_user, id) do
    id = Helpers.parse_int(id)

    case id && Repo.get(Subscription, id) do
      %Subscription{} = sub ->
        Repo.preload(sub, [:feed, :category])

      _ ->
        nil
    end
  end

  def owned_category(_user, id) do
    id = Helpers.parse_int(id)

    case id && Reader.get_category(id) do
      %Category{} = cat -> cat
      _ -> nil
    end
  end

  def authorized_feed(_user, feed_id) do
    cond do
      is_nil(feed_id) ->
        :forbidden

      Reader.get_subscription(feed_id) ->
        :ok

      true ->
        :forbidden
    end
  end
end
