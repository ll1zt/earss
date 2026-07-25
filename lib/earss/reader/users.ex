defmodule Earss.Reader.Users do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Feeds
  alias Earss.Feeds.Feed
  alias Earss.Reader.User
  alias Earss.Reader.Subscription

  def create_sub_user(username, password), do: create_user(username, password, "sub_user")

  def create_user(username, password, user_type \\ "admin") do
    username = String.trim(username)

    %{
      username: username,
      password_hash: Argon2.hash_pwd_salt(password),
      user_type: user_type,
      fever_api_key: fever_api_key(username, password)
    }
    |> do_create_user()
  end

  defp do_create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username)
  end

  def get_user_by_fever_api_key(api_key) when is_binary(api_key) do
    key = String.downcase(String.trim(api_key))

    case Repo.get_by(User, fever_api_key: key) do
      %User{is_active: true} = user -> user
      _ -> nil
    end
  end

  def get_user_by_fever_api_key(_), do: nil

  def authenticate_user(username, password) do
    user = Repo.get_by(User, username: username)

    cond do
      user && user.is_active && Argon2.verify_pass(password, user.password_hash) ->
        {:ok, user}

      user && not user.is_active ->
        Argon2.no_user_verify()
        {:error, :unauthorized}

      user ->
        {:error, :unauthorized}

      true ->
        Argon2.no_user_verify()
        {:error, :not_found}
    end
  end

  @doc """
  Update login password and recompute Fever api_key from the new password.
  """
  def set_password(%User{} = user, password) when is_binary(password) do
    user
    |> User.changeset(%{
      password_hash: Argon2.hash_pwd_salt(password),
      fever_api_key: fever_api_key(user.username, password)
    })
    |> Repo.update()
  end

  @doc """
  Set a Fever-only secret (does not change login password).

  Clients compute api_key = md5(username <> ":" <> secret).
  """
  def set_fever_password(%User{} = user, secret) when is_binary(secret) do
    user
    |> User.changeset(%{fever_api_key: fever_api_key(user.username, secret)})
    |> Repo.update()
  end

  @doc """
  Fever api_key = lowercase hex md5(username || ":" || secret).
  """
  def fever_api_key(username, secret)
      when is_binary(username) and is_binary(secret) do
    :crypto.hash(:md5, "#{username}:#{secret}") |> Base.encode16(case: :lower)
  end

  @doc """
  Soft-disable a user (`is_active = false`). Auth will fail afterwards.
  """
  def deactivate_user(%User{} = user) do
    user
    |> User.changeset(%{is_active: false})
    |> Repo.update()
  end

  def delete_user(username, password) do
    case authenticate_user(username, password) do
      {:ok, user} -> do_delete_user(user)
      error -> error
    end
  end

  def delete_user(admin_username, admin_password, sub_user_username) do
    case authenticate_user(admin_username, admin_password) do
      {:ok, %{user_type: "admin"}} ->
        case Repo.get_by(User, username: sub_user_username) do
          nil -> {:error, :not_found}
          target_user -> do_delete_user(target_user)
        end

      {:ok, _not_admin} ->
        {:error, :unauthorized}

      error ->
        error
    end
  end

  defp do_delete_user(%User{} = user) do
    feed_ids =
      Subscription
      |> where([s], s.user_id == ^user.id)
      |> select([s], s.feed_id)
      |> Repo.all()

    Repo.transaction(fn ->
      case Repo.delete(user) do
        {:ok, user} ->
          Enum.each(feed_ids, &maybe_mark_feed_unsubscribed/1)
          user

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # Same contract as subscription unsubscribe zero-subscriber bookkeeping.
  defp maybe_mark_feed_unsubscribed(feed_id) do
    remaining =
      Subscription
      |> where([s], s.feed_id == ^feed_id)
      |> Repo.aggregate(:count)

    if remaining == 0 do
      case Feeds.get_feed(feed_id) do
        nil ->
          :ok

        feed ->
          feed
          |> Feed.changeset(%{last_unsubscribed_at: utc_now()})
          |> Repo.update()
      end
    else
      :ok
    end
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
