defmodule Earss.Bootstrap do
  @moduledoc """
  First-boot helpers.

  When the `users` table is empty, creates a default admin so operators can log
  into `/admin` without manual `eval` / `seed_admin`. Change the password under
  **Settings** after first login.
  """

  require Logger

  import Ecto.Query, warn: false

  alias Earss.Reader
  alias Earss.Reader.User
  alias Earss.Repo

  @default_username "admin"
  @default_password "changeme"

  @doc """
  If there are zero users, create the default admin.

  Options / env (read at call time):

    * Application `:earss, :bootstrap_admin, :enabled` (default `true`)
    * `EARSS_BOOTSTRAP_ADMIN=false` disables
    * `EARSS_DEFAULT_ADMIN_USER` / config `:username` (default `admin`)
    * `EARSS_DEFAULT_ADMIN_PASSWORD` / config `:password` (default `changeme`)

  Always returns `:ok` (errors are logged; startup continues).
  """
  @spec ensure_default_admin() :: :ok
  def ensure_default_admin do
    if enabled?() do
      do_ensure()
    else
      :ok
    end
  rescue
    e ->
      Logger.error("bootstrap admin failed: #{Exception.message(e)}")
      :ok
  end

  defp do_ensure do
    case Repo.aggregate(from(u in User), :count, :id) do
      n when is_integer(n) and n > 0 ->
        :ok

      0 ->
        username = username()
        password = password()

        case Reader.create_user(username, password, "admin") do
          {:ok, _user} ->
            Logger.warning("""
            Earss bootstrap: created default admin user.

              username: #{username}
              password: #{password}

            Sign in at /admin and change the password under Settings immediately.
            Disable with EARSS_BOOTSTRAP_ADMIN=false after first setup if desired.
            """)

            :ok

          {:error, reason} ->
            Logger.error("bootstrap admin create failed: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp enabled? do
    case System.get_env("EARSS_BOOTSTRAP_ADMIN") do
      v when v in ~w(false 0 no off) -> false
      v when v in ~w(true 1 yes on) -> true
      _ -> Keyword.get(cfg(), :enabled, true) != false
    end
  end

  defp username do
    System.get_env("EARSS_DEFAULT_ADMIN_USER") ||
      Keyword.get(cfg(), :username) ||
      @default_username
  end

  defp password do
    System.get_env("EARSS_DEFAULT_ADMIN_PASSWORD") ||
      Keyword.get(cfg(), :password) ||
      @default_password
  end

  defp cfg, do: Application.get_env(:earss, :bootstrap_admin, [])
end
