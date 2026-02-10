defmodule Earss.Reader do
  @moduledoc """
  The Reader context.
  Handles user subscriptions, categories, and entry states.
  """

  import Ecto.Query, warn: false
  alias Earss.Repo
  alias Earss.Reader.User
  alias Earss.Reader.Category
  alias Earss.Reader.Subscription
  alias Earss.Reader.EntryState

  def create_sub_user(username, password), do: create_user(username, password, "sub_user")

  def create_user(username, password, user_type \\ "admin") do
    %{
      username: username,
      password_hash: Argon2.hash_pwd_salt(password),
      user_type: user_type
    }
    |> do_create_user()
  end

  defp do_create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def authenticate_user(username, password) do
    user = Repo.get_by(User, username: username)

    cond do
      user && Argon2.verify_pass(password, user.password_hash) ->
        {:ok, user}

      user ->
        {:error, :unauthorized}

      true ->
        Argon2.no_user_verify()
        {:error, :not_found}
    end
  end

  def delete_user(username, password) do
    case authenticate_user(username, password) do
      {:ok, user} ->
        do_delete_user(user)

      error ->
        error
    end
  end

  def delete_user(admin_username, admin_password, sub_user_username) do
    case authenticate_user(admin_username, admin_password) do
      {:ok, user_type: "admin"} ->
        case Repo.get_by(User, sub_user_username) do
          nil -> {:error, :not_found}
          target_user -> do_delete_user(target_user)
        end

      {:ok, _not_admin} ->
        {:error, :unauthorized}

      error ->
        error
    end
  end

  defp do_delete_user(%User{} = user), do: Repo.delete(user)

  # Business logic to be implemented by user
end
