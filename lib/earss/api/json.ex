defmodule Earss.API.JSON do
  @moduledoc false

  import Plug.Conn

  def json(conn, status, body) when is_map(body) or is_list(body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  def error(conn, status, message, extra \\ %{}) when is_binary(message) do
    json(conn, status, Map.merge(%{error: message}, extra))
  end

  def changeset_error(conn, %Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    error(conn, 422, "validation_failed", %{details: errors})
  end
end
