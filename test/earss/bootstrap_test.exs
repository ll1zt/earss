defmodule Earss.BootstrapTest do
  use Earss.DataCase

  import ExUnit.CaptureLog

  alias Earss.Bootstrap
  alias Earss.Repo
  alias Earss.Reader.User

  import Ecto.Query

  setup do
    # App boots with bootstrap disabled in test; re-enable for these cases.
    prev_env = System.get_env("EARSS_BOOTSTRAP_ADMIN")
    System.delete_env("EARSS_BOOTSTRAP_ADMIN")
    prev_cfg = Application.get_env(:earss, :bootstrap_admin, [])

    Application.put_env(:earss, :bootstrap_admin, enabled: true)

    on_exit(fn ->
      if prev_env,
        do: System.put_env("EARSS_BOOTSTRAP_ADMIN", prev_env),
        else: System.delete_env("EARSS_BOOTSTRAP_ADMIN")

      Application.put_env(:earss, :bootstrap_admin, prev_cfg)
    end)

    :ok
  end

  test "seeds the anchor user row when no users exist" do
    Repo.delete_all(User)

    assert :ok = Bootstrap.ensure_operator()

    assert Repo.aggregate(from(u in User), :count, :id) == 1
    assert [user] = Repo.all(User)
    assert user.username == "operator"
  end

  test "is a no-op when a user row already exists" do
    Repo.delete_all(User)

    %User{}
    |> User.changeset(%{username: "existing", password_hash: "x", user_type: "admin"})
    |> Repo.insert!()

    assert :ok = Bootstrap.ensure_operator()
    assert Repo.aggregate(from(u in User), :count, :id) == 1
    assert Repo.one!(from u in User, select: u.username) == "existing"
  end

  test "warns when the operator password is not configured" do
    Repo.delete_all(User)
    prev_cfg = Application.get_env(:earss, :operator_auth, [])

    Application.put_env(:earss, :operator_auth, Keyword.drop(prev_cfg, [:admin_password]))

    on_exit(fn -> Application.put_env(:earss, :operator_auth, prev_cfg) end)

    assert capture_log(fn ->
             assert :ok = Bootstrap.ensure_operator()
           end) =~ "ADMIN_PASSWORD is not set"
  end

  test "warns when the fever api key is not configured" do
    Repo.delete_all(User)
    prev_cfg = Application.get_env(:earss, :operator_auth, [])

    Application.put_env(:earss, :operator_auth, Keyword.drop(prev_cfg, [:fever_api_key]))

    on_exit(fn -> Application.put_env(:earss, :operator_auth, prev_cfg) end)

    assert capture_log(fn ->
             assert :ok = Bootstrap.ensure_operator()
           end) =~ "FEVER_API_KEY is not set"
  end
end
