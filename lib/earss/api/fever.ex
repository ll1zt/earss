defmodule Earss.API.Fever do
  @moduledoc """
  Plug endpoint for Fever-compatible clients (`/fever`).
  """

  @behaviour Plug

  import Plug.Conn
  alias Earss.Fever

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    params = merge_params(conn)
    ip = Earss.RateLimit.client_ip(conn)

    # Require ?api or api= form flag (classic Fever)
    cond do
      not api_requested?(params, conn) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"api_version" => 3, "auth" => 0}))

      Earss.RateLimit.check(:fever, ip) == {:error, :rate_limited} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{"api_version" => 3, "auth" => 0}))

      true ->
        body = Fever.handle(params)

        if body["auth"] == 0 do
          Earss.RateLimit.report_failure(:fever, ip)
        end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(body))
    end
  end

  defp api_requested?(params, conn) do
    Map.has_key?(params, "api") or
      conn.query_string == "api" or
      String.contains?(conn.query_string, "api")
  end

  defp merge_params(conn) do
    body =
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> %{}
        %{} = m -> m
        _ -> %{}
      end

    Map.merge(conn.query_params, body)
  end
end
