defmodule Earss.API.Auth do
  @moduledoc """
  Loads current user from `Authorization: Bearer <token>`.
  """

  import Plug.Conn
  alias Earss.API.Token
  alias Earss.API.JSON
  alias Earss.Reader

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer_token(conn) do
      nil ->
        conn
        |> JSON.error(401, "missing_token")
        |> halt()

      token ->
        case Token.verify(token) do
          {:ok, user_id} ->
            case Reader.get_user(user_id) do
              %{is_active: true} = user ->
                assign(conn, :current_user, user)

              _ ->
                conn
                |> JSON.error(401, "invalid_token")
                |> halt()
            end

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
