defmodule Earss.API.Token do
  @moduledoc """
  Signed Bearer tokens for the HTTP API (no server-side session store).
  """

  @salt "earss.api.auth"

  @doc """
  Sign a token for the given user id.
  """
  @spec sign(pos_integer()) :: String.t()
  def sign(user_id) when is_integer(user_id) do
    Plug.Crypto.sign(secret(), @salt, %{user_id: user_id})
  end

  @doc """
  Verify token and return `{:ok, user_id}` or `:error`.
  """
  @spec verify(String.t()) :: {:ok, pos_integer()} | :error
  def verify(token) when is_binary(token) do
    max_age = api_config() |> Keyword.get(:token_max_age_secs, 60 * 60 * 24 * 30)

    case Plug.Crypto.verify(secret(), @salt, token, max_age: max_age) do
      {:ok, %{user_id: user_id}} when is_integer(user_id) -> {:ok, user_id}
      {:ok, %{"user_id" => user_id}} when is_integer(user_id) -> {:ok, user_id}
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
