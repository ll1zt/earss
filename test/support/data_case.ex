defmodule Earss.DataCase do
  @moduledoc """
  Test case for tests that need the database.
  """

  use ExUnit.CaseTemplate

  alias Earss.Repo

  using do
    quote do
      alias Earss.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Earss.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Earss.Repo, shared: not tags[:async])
    ensure_anchor_user!()
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Insert the single operator's anchor user row when the users table is empty.

  During the single-user transition (docs/single_user.md) reading rows still
  carry a `user_id` pinned to `Earss.Reader.AnchorUser.id/0`; tests therefore
  need one user row per sandbox transaction.
  """
  def ensure_anchor_user! do
    case Repo.aggregate(Earss.Reader.User, :count) do
      0 ->
        %Earss.Reader.User{}
        |> Earss.Reader.User.changeset(%{
          username: "operator",
          password_hash: "test-hash",
          user_type: "admin"
        })
        |> Repo.insert!()

      _ ->
        :ok
    end
  end

  @doc """
  Raises if changeset is invalid; returns the struct/changeset data on ok.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
