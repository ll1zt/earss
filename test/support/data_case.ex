defmodule Earss.DataCase do
  @moduledoc """
  Test case for tests that need the database.
  """

  use ExUnit.CaseTemplate

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
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
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
