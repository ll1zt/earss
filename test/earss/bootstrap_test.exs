defmodule Earss.BootstrapTest do
  use Earss.DataCase

  alias Earss.Bootstrap
  alias Earss.Reader
  alias Earss.Reader.User
  alias Earss.Repo

  import Ecto.Query

  setup do
    # Clear any leftover users (e.g. committed outside sandbox in older runs).
    Repo.delete_all(User)

    # App boots with bootstrap disabled in test; re-enable for these cases.
    prev_env = System.get_env("EARSS_BOOTSTRAP_ADMIN")
    System.delete_env("EARSS_BOOTSTRAP_ADMIN")
    prev_cfg = Application.get_env(:earss, :bootstrap_admin, [])

    Application.put_env(:earss, :bootstrap_admin,
      enabled: true,
      username: "admin",
      password: "changeme"
    )

    on_exit(fn ->
      if prev_env,
        do: System.put_env("EARSS_BOOTSTRAP_ADMIN", prev_env),
        else: System.delete_env("EARSS_BOOTSTRAP_ADMIN")

      Application.put_env(:earss, :bootstrap_admin, prev_cfg)
    end)

    :ok
  end

  test "creates default admin when no users exist" do
    assert Repo.aggregate(from(u in User), :count, :id) == 0

    assert :ok = Bootstrap.ensure_default_admin()

    user = Reader.get_user_by_username("admin")
    assert user
    assert user.user_type == "admin"
    assert {:ok, _} = Reader.authenticate_user("admin", "changeme")
  end

  test "is a no-op when users already exist" do
    {:ok, _} = Reader.create_user("existing", "secret")
    assert :ok = Bootstrap.ensure_default_admin()
    refute Reader.get_user_by_username("admin")
  end

  test "respects EARSS_BOOTSTRAP_ADMIN=false" do
    System.put_env("EARSS_BOOTSTRAP_ADMIN", "false")
    assert :ok = Bootstrap.ensure_default_admin()
    assert Repo.aggregate(from(u in User), :count, :id) == 0
  end
end
