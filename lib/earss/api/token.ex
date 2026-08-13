defmodule Earss.API.Token do
  @moduledoc """
  Signed Bearer tokens for the HTTP API (no server-side session store).

  Single-operator mode (docs/single_user.md): tokens carry a fixed operator
  claim instead of a user id — there is exactly one operator.
  """

  @salt "earss.api.auth"
  @operator_claim %{operator: "earss"}

  @doc """
  Sign a token for the single operator.
  """
  @spec sign_operator() :: String.t()
  def sign_operator do
    Plug.Crypto.sign(secret(), @salt, @operator_claim)
  end

  @doc """
  Verify token and return `{:ok, :operator}` or `:error`.
  """
  @spec verify(String.t()) :: {:ok, :operator} | :error
  def verify(token) when is_binary(token) do
    max_age = api_config() |> Keyword.get(:token_max_age_secs, 60 * 60 * 24 * 30)

    case Plug.Crypto.verify(secret(), @salt, token, max_age: max_age) do
      {:ok, %{operator: "earss"}} -> {:ok, :operator}
      {:ok, %{"operator" => "earss"}} -> {:ok, :operator}
      _ -> :error
    end
  end

  def verify(_), do: :error

  defp secret do
    api_config()
    |> Keyword.get(:secret_key_base) ||
      raise "config :earss, :api, secret_key_base is not set"
  end

  defp api_config, do: Application.get_env(:earss, :api, [])
end
