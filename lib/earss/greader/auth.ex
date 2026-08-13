defmodule Earss.GReader.Auth do
  @moduledoc false

  alias Earss.OperatorAuth

  @salt "earss.greader.auth"
  @edit_salt "earss.greader.edit"
  @operator_claim %{operator: "earss"}

  def issue_auth(_operator \\ nil), do: Plug.Crypto.sign(secret(), @salt, @operator_claim)

  def verify_auth(token) when is_binary(token) do
    max_age =
      Application.get_env(:earss, :api, [])
      |> Keyword.get(:token_max_age_secs, 60 * 60 * 24 * 30)

    case Plug.Crypto.verify(secret(), @salt, token, max_age: max_age) do
      {:ok, %{operator: "earss"}} -> OperatorAuth.operator()
      {:ok, %{"operator" => "earss"}} -> OperatorAuth.operator()
      _ -> nil
    end
  end

  def verify_auth(_), do: nil

  def issue_edit_token(_operator \\ nil),
    do: Plug.Crypto.sign(secret(), @edit_salt, @operator_claim)

  def verify_edit_token(_operator, token) when is_binary(token) do
    case Plug.Crypto.verify(secret(), @edit_salt, token, max_age: 60 * 60 * 24) do
      {:ok, %{operator: "earss"}} -> true
      {:ok, %{"operator" => "earss"}} -> true
      _ -> is_map(verify_auth(token))
    end
  end

  def verify_edit_token(_, _), do: false

  def client_login(_email, password) do
    if OperatorAuth.verify_admin_password(password || "") do
      {:ok, issue_auth()}
    else
      :error
    end
  end

  defp secret do
    Application.get_env(:earss, :api, [])
    |> Keyword.get(:secret_key_base) ||
      raise "secret_key_base missing"
  end
end
