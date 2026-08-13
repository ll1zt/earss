defmodule Earss.API.Auth do
  @moduledoc """
  Validates `Authorization: Bearer <token>` and assigns the operator.

  Single-operator mode (docs/single_user.md): a valid token means "the
  operator"; there is no per-user resolution.
  """

  import Plug.Conn
  alias Earss.API.Token
  alias Earss.API.JSON
  alias Earss.OperatorAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer_token(conn) do
      nil ->
        conn
        |> JSON.error(401, "missing_token")
        |> halt()

      token ->
        case Token.verify(token) do
          {:ok, :operator} ->
            assign(conn, :current_user, OperatorAuth.operator())

          :error ->
            conn
            |> JSON.error(401, "invalid_token")
            |> halt()
        end
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end
end
