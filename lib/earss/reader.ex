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

  # Business logic to be implemented by user
end
