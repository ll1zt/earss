defmodule Earss.ConnCase do
  @moduledoc """
  Test case for Plug API tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Plug.Test
      import ExUnit.Assertions
      import Earss.ConnCase

      alias Earss.API.Router
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Earss.Repo, shared: not tags[:async])
    Earss.DataCase.ensure_anchor_user!()
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Call the API router with a JSON body.
  """
  def json_req(method, path, body \\ nil, headers \\ []) do
    body_bin = if body, do: Jason.encode!(body), else: nil

    headers =
      headers
      |> Enum.map(fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        other -> other
      end)
      |> then(fn h ->
        if body_bin do
          [{"content-type", "application/json"} | h]
        else
          h
        end
      end)

    conn =
      Plug.Test.conn(method, path, body_bin)
      |> Map.put(:host, "www.example.com")

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c ->
        Plug.Conn.put_req_header(c, String.downcase(k), v)
      end)

    Earss.API.Router.call(conn, Earss.API.Router.init([]))
  end

  def auth_header(token), do: [{"authorization", "Bearer #{token}"}]

  def login_token do
    conn = json_req(:post, "/api/auth/login", %{password: "test-password"})
    assert conn.status == 200
    Jason.decode!(conn.resp_body)["token"]
  end
end
