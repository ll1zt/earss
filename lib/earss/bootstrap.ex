defmodule Earss.Bootstrap do
  @moduledoc """
  First-boot helpers for single-operator mode (docs/single_user.md).

  Keeps one anchor user row (needed by `Earss.Reader.AnchorUser` until the
  db-schema-v2 migration drops the users table) and warns when the operator
  credentials (`ADMIN_PASSWORD` / `FEVER_API_KEY`) are not configured.
  Credentials themselves live in the operator environment only.
  """

  require Logger

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Reader.User
  alias Earss.OperatorAuth

  @doc """
  Seed the anchor user row when the users table is empty, then validate the
  operator credentials and log guidance.

  Options / env (read at call time):

    * Application `:earss, :bootstrap_admin, :enabled` (default `true`)
    * `EARSS_BOOTSTRAP_ADMIN=false` disables

  Always returns `:ok` (errors are logged; startup continues).
  """
  @spec ensure_operator() :: :ok
  def ensure_operator do
    if enabled?() do
      ensure_anchor_user()
      check_credentials()
    else
      :ok
    end
  rescue
    e ->
      Logger.error("bootstrap failed: #{Exception.message(e)}")
      :ok
  end

  defp ensure_anchor_user do
    case Repo.aggregate(from(u in User), :count, :id) do
      n when is_integer(n) and n > 0 ->
        :ok

      0 ->
        %User{}
        |> User.changeset(%{
          username: "operator",
          # placeholder — authentication never reads this row (C2)
          password_hash: "operator-anchor",
          user_type: "admin"
        })
        |> Repo.insert()
        |> case do
          {:ok, _} ->
            Logger.info("Earss bootstrap: created the operator anchor row")
            :ok

          {:error, reason} ->
            Logger.error("bootstrap anchor insert failed: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp check_credentials do
    cond do
      is_nil(OperatorAuth.admin_password()) ->
        Logger.warning("""
        Earss bootstrap: ADMIN_PASSWORD is not set (earss.env / environment).

        The admin UI and API login reject every attempt until a password is
        configured. Add:

          ADMIN_PASSWORD=<a strong password>

        to earss.env and restart.
        """)

      true ->
        :ok
    end

    cond do
      is_nil(OperatorAuth.fever_api_key()) ->
        Logger.warning("""
        Earss bootstrap: FEVER_API_KEY is not set (earss.env / environment).

        NetNewsWire Fever accounts cannot authenticate until a key is
        configured. Add:

          FEVER_API_KEY=<random hex>

        to earss.env and restart.
        """)

      true ->
        :ok
    end

    :ok
  end

  defp enabled? do
    case System.get_env("EARSS_BOOTSTRAP_ADMIN") do
      v when v in ~w(false 0 no off) -> false
      v when v in ~w(true 1 yes on) -> true
      _ -> Keyword.get(cfg(), :enabled, true) != false
    end
  end

  defp cfg, do: Application.get_env(:earss, :bootstrap_admin, [])
end
