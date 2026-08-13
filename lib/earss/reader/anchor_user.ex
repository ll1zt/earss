defmodule Earss.Reader.AnchorUser do
  @moduledoc """
  Adapter for the single operator's user row.

  Exists only until the `db-schema-v2` migration removes the `users` table
  (see docs/single_user.md, C5). Every query that formerly scoped by
  `user_id` now scopes by this fixed id instead.
  """

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Reader.User

  @doc """
  The single operator's user id (first row by id).

  Raises when no user row exists — the bootstrap/admin seed must have run
  first; the migration in C5 removes this requirement entirely.
  """
  @spec id() :: pos_integer()
  def id do
    from(u in User, select: u.id, order_by: [asc: u.id], limit: 1)
    |> Repo.one()
    |> case do
      nil -> raise "no user row found — seed a user first (see Earss.Bootstrap)"
      user_id -> user_id
    end
  end
end
