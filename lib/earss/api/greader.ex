defmodule Earss.API.GReader do
  @moduledoc """
  Google Reader API (FreshRSS-compatible) Plug.

  Mounted at `/api/greader.php` — remaining path is ClientLogin, reader/api/0/*, etc.
  """

  @behaviour Plug

  import Plug.Conn
  alias Earss.GReader
  alias Earss.Reader.User

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    # path_info after forward: e.g. ["accounts", "ClientLogin"] or ["reader", "api", "0", ...]
    path = Enum.join(conn.path_info, "/")
    params = merge_params(conn)

    cond do
      path in ["accounts/ClientLogin", "accounts/ClientLogin/"] ->
        client_login(conn, params)

      path in ["reader/api/0/token", "reader/api/0/token/"] ->
        with_user(conn, params, fn user, c ->
          text(c, 200, GReader.issue_edit_token(user))
        end)

      path in ["reader/api/0/user-info", "reader/api/0/user-info/"] ->
        with_user(conn, params, fn user, c ->
          json(c, 200, GReader.user_info(user))
        end)

      path in ["reader/api/0/subscription/list", "reader/api/0/subscription/list/"] ->
        with_user(conn, params, fn user, c ->
          json(c, 200, GReader.subscription_list(user))
        end)

      path in ["reader/api/0/tag/list", "reader/api/0/tag/list/"] ->
        with_user(conn, params, fn user, c ->
          json(c, 200, GReader.tag_list(user))
        end)

      String.starts_with?(path, "reader/api/0/stream/contents/") ->
        stream_id =
          path
          |> String.replace_prefix("reader/api/0/stream/contents/", "")
          |> URI.decode()

        with_user(conn, params, fn user, c ->
          opts = stream_opts(params)
          json(c, 200, GReader.stream_contents(user, stream_id, opts))
        end)

      path in ["reader/api/0/stream/items/ids", "reader/api/0/stream/items/ids/"] ->
        with_user(conn, params, fn user, c ->
          stream_id = params["s"] || "user/-/state/com.google/reading-list"
          opts = stream_opts(params)
          json(c, 200, GReader.stream_item_ids(user, stream_id, opts))
        end)

      path in ["reader/api/0/stream/items/contents", "reader/api/0/stream/items/contents/"] ->
        with_user(conn, params, fn user, c ->
          ids = List.wrap(params["i"])
          json(c, 200, GReader.items_contents(user, ids))
        end)

      path in ["reader/api/0/edit-tag", "reader/api/0/edit-tag/"] ->
        with_user(conn, params, fn user, c ->
          _ = GReader.edit_tag(user, params["i"], params["a"], params["r"])
          text(c, 200, "OK")
        end)

      path in ["reader/api/0/mark-all-as-read", "reader/api/0/mark-all-as-read/"] ->
        with_user(conn, params, fn user, c ->
          stream = params["s"]
          ts = params["ts"]
          _ = GReader.mark_all_as_read(user, stream, ts)
          text(c, 200, "OK")
        end)

      path in ["check/compatibility", "check/compatibility/", ""] ->
        # FreshRSS health / root
        text(conn, 200, "OK")

      true ->
        # Some clients hit /api/greader.php without path for probe
        if path == "" or path == "/" do
          text(conn, 200, "OK")
        else
          json(conn, 404, %{"error" => "not_found", "path" => path})
        end
    end
  end

  defp client_login(conn, params) do
    email = params["Email"] || params["email"]
    pass = params["Passwd"] || params["password"] || params["Passwd"]

    case GReader.client_login(email, pass) do
      {:ok, auth} ->
        body = "SID=#{auth}\nLSID=#{auth}\nAuth=#{auth}\n"
        text(conn, 200, body)

      :error ->
        text(conn, 403, "Error=BadAuthentication")
    end
  end

  defp with_user(conn, params, fun) do
    case current_user(conn, params) do
      %User{} = user ->
        fun.(user, conn)

      nil ->
        text(conn, 401, "Error=AuthRequired")
    end
  end

  defp current_user(conn, params) do
    token =
      bearer_or_google(conn) ||
        params["Authorization"] ||
        params["auth"] ||
        params["T"]

    token = token && strip_auth_prefix(token)
    token && GReader.verify_auth(token)
  end

  defp bearer_or_google(conn) do
    case get_req_header(conn, "authorization") do
      ["GoogleLogin auth=" <> auth] ->
        String.trim(auth)

      ["GoogleLogin Auth=" <> auth] ->
        String.trim(auth)

      ["Bearer " <> auth] ->
        String.trim(auth)

      ["bearer " <> auth] ->
        String.trim(auth)

      [other] ->
        # GoogleLogin auth=xxx in various casings
        case Regex.run(~r/auth=(\S+)/i, other) do
          [_, a] -> a
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp strip_auth_prefix("GoogleLogin auth=" <> rest), do: String.trim(rest)
  defp strip_auth_prefix("GoogleLogin Auth=" <> rest), do: String.trim(rest)
  defp strip_auth_prefix(t), do: t

  defp stream_opts(params) do
    n =
      case Integer.parse(to_string(params["n"] || "50")) do
        {i, _} -> i
        :error -> 50
      end

    exclude_read =
      case params["xt"] do
        nil -> false
        xt -> String.contains?(to_string(xt), "state/com.google/read")
      end

    [
      n: n,
      exclude_read: exclude_read,
      continuation: params["c"]
    ]
  end

  defp merge_params(conn) do
    body =
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> %{}
        %{} = m -> m
        _ -> %{}
      end

    # query overrides body for GET-style; merge both
    Map.merge(body, conn.query_params)
  end

  defp json(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
  end

  defp text(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain; charset=utf-8")
    |> send_resp(status, body)
  end
end
