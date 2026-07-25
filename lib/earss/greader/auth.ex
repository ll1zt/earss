defmodule Earss.GReader.Auth do
  @moduledoc false

  alias Earss.Reader
  alias Earss.Reader.User

  @salt "earss.greader.auth"
  @edit_salt "earss.greader.edit"

  def issue_auth(%User{id: id}), do: Plug.Crypto.sign(secret(), @salt, %{uid: id})

  def verify_auth(token) when is_binary(token) do
    max_age =
      Application.get_env(:earss, :api, [])
      |> Keyword.get(:token_max_age_secs, 60 * 60 * 24 * 30)

    user =
      case Plug.Crypto.verify(secret(), @salt, token, max_age: max_age) do
        {:ok, %{uid: uid}} when is_integer(uid) -> Reader.get_user(uid)
        {:ok, %{"uid" => uid}} when is_integer(uid) -> Reader.get_user(uid)
        _ -> nil
      end

    case user do
      %User{is_active: true} = u -> u
      _ -> nil
    end
  end

  def verify_auth(_), do: nil

  def issue_edit_token(%User{id: id}), do: Plug.Crypto.sign(secret(), @edit_salt, %{uid: id})

  def verify_edit_token(%User{id: id}, token) when is_binary(token) do
    case Plug.Crypto.verify(secret(), @edit_salt, token, max_age: 60 * 60 * 24) do
      {:ok, %{uid: ^id}} -> true
      {:ok, %{"uid" => ^id}} -> true
      _ -> match?(%User{}, verify_auth(token))
    end
  end

  def verify_edit_token(_, _), do: false

  def client_login(email, password) do
    case Reader.authenticate_user(email || "", password || "") do
      {:ok, user} ->
        {:ok, issue_auth(user)}

      {:error, _} ->
        user = Reader.get_user_by_username(email || "")

        if user && user.fever_api_key &&
             user.fever_api_key == Reader.fever_api_key(user.username, password || "") do
          {:ok, issue_auth(user)}
        else
          :error
        end
    end
  end

  defp secret do
    Application.get_env(:earss, :api, [])
    |> Keyword.get(:secret_key_base) ||
      raise "secret_key_base missing"
  end
end
