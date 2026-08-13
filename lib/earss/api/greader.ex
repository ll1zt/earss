defmodule Earss.API.GReader do
  @moduledoc """
  Google Reader API (FreshRSS-compatible) Plug.

  Mounted at `/api/greader.php` — remaining path is ClientLogin, reader/api/0/*, etc.
  """

  @behaviour Plug

  require Logger

  import Plug.Conn
  alias Earss.GReader

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    path = path_from_conn(conn)
    params = merge_params(conn)

    Logger.debug("GReader path=#{inspect(path)} qs=#{conn.query_string}")

    cond do
      client_login_path?(path) ->
        client_login(conn, params)

      ends_with_path?(path, "reader/api/0/token") ->
        with_user(conn, params, fn _user, c ->
          text(c, 200, GReader.issue_edit_token())
        end)

      ends_with_path?(path, "reader/api/0/user-info") ->
        with_user(conn, params, fn _user, c ->
          json(c, 200, GReader.user_info())
        end)

      ends_with_path?(path, "reader/api/0/subscription/list") ->
        with_user(conn, params, fn _user, c ->
          json(c, 200, GReader.subscription_list())
        end)

      ends_with_path?(path, "reader/api/0/tag/list") ->
        with_user(conn, params, fn _user, c ->
          json(c, 200, GReader.tag_list())
        end)

      ends_with_path?(path, "reader/api/0/unread-count") ->
        with_user(conn, params, fn user, c ->
          payload = GReader.unread_count()

          total =
            payload["unreadcounts"]
            |> Enum.find(%{}, &(&1["id"] == "user/-/state/com.google/reading-list"))
            |> Map.get("count", 0)

          Logger.info("GReader unread-count user=#{user.username} total=#{total}")
          json(c, 200, payload)
        end)

      stream_contents_path?(path) ->
        stream_id =
          path
          |> stream_contents_stream_id()
          |> GReader.normalize_stream_id()

        with_user(conn, params, fn _user, c ->
          opts = stream_opts(params)
          json(c, 200, GReader.stream_contents(stream_id, opts))
        end)

      ends_with_path?(path, "reader/api/0/stream/items/ids") ->
        with_user(conn, params, fn _user, c ->
          stream_id =
            (params["s"] || "user/-/state/com.google/reading-list")
            |> GReader.normalize_stream_id()

          opts = stream_opts(params)
          payload = GReader.stream_item_ids(stream_id, opts)

          Logger.info(
            "GReader items/ids stream=#{stream_id} xt_read=#{opts[:exclude_read]} ot=#{inspect(opts[:ot])} n=#{length(payload["itemRefs"])} cont=#{inspect(payload["continuation"])}"
          )

          json(c, 200, payload)
        end)

      ends_with_path?(path, "reader/api/0/stream/items/contents") ->
        with_user(conn, params, fn _user, c ->
          ids = multi_param(c, params, "i")

          Logger.info(
            "GReader items/contents requested=#{length(ids)} sample=#{inspect(Enum.take(ids, 3))}"
          )

          payload = GReader.items_contents(ids, original: params["original"] == "1")
          Logger.info("GReader items/contents returned=#{length(payload["items"])}")
          json(c, 200, payload)
        end)

      ends_with_path?(path, "reader/api/0/edit-tag") ->
        with_user(conn, params, fn user, c ->
          case require_edit_token(user, params) do
            :ok ->
              ids = multi_param(c, params, "i")
              add = multi_param(c, params, "a")
              remove = multi_param(c, params, "r")
              _ = GReader.edit_tag(ids, add, remove)
              text(c, 200, "OK")

            :error ->
              text(c, 401, "Error=InvalidToken")
          end
        end)

      ends_with_path?(path, "reader/api/0/mark-all-as-read") ->
        with_user(conn, params, fn user, c ->
          case require_edit_token(user, params) do
            :ok ->
              stream = GReader.normalize_stream_id(params["s"])
              ts = params["ts"]
              _ = GReader.mark_all_as_read(stream, ts)
              text(c, 200, "OK")

            :error ->
              text(c, 401, "Error=InvalidToken")
          end
        end)

      ends_with_path?(path, "reader/api/0/subscription/edit") ->
        with_user(conn, params, fn user, c ->
          case require_edit_token(user, params) do
            :ok ->
              case GReader.subscription_edit(params) do
                :ok ->
                  text(c, 200, "OK")

                {:ok, _} ->
                  text(c, 200, "OK")

                {:error, :bad_request} ->
                  text(c, 400, "Error=BadRequest")

                {:error, :not_found} ->
                  text(c, 404, "Error=NotFound")

                {:error, %Ecto.Changeset{}} ->
                  text(c, 400, "Error=BadRequest")

                {:error, _} ->
                  text(c, 400, "Error=BadRequest")
              end

            :error ->
              text(c, 401, "Error=InvalidToken")
          end
        end)

      path in ["check/compatibility", "check/compatibility/", "", "/"] ->
        text(conn, 200, "OK")

      true ->
        Logger.warning(
          "GReader unmatched path=#{inspect(path)} request_path=#{conn.request_path}"
        )

        json(conn, 404, %{"error" => "not_found", "path" => path})
    end
  end

  defp path_from_conn(conn) do
    # Prefer path_info (after forward). Fallback to request_path strip.
    case Enum.join(conn.path_info, "/") do
      "" ->
        conn.request_path
        |> String.replace_prefix("/api/greader.php", "")
        |> String.trim_leading("/")

      path ->
        path
    end
  end

  defp ends_with_path?(path, suffix) do
    path = String.trim_trailing(path || "", "/")
    suffix = String.trim_trailing(suffix, "/")
    path == suffix or String.ends_with?(path, suffix)
  end

  defp client_login_path?(path) do
    ends_with_path?(path, "accounts/ClientLogin") or
      ends_with_path?(path, "accounts/ClientLogin/")
  end

  defp stream_contents_path?(path) do
    String.contains?(path || "", "reader/api/0/stream/contents/")
  end

  defp stream_contents_stream_id(path) do
    case String.split(path, "reader/api/0/stream/contents/", parts: 2) do
      [_, rest] -> URI.decode(rest)
      _ -> ""
    end
  end

  defp client_login(conn, params) do
    email = params["Email"] || params["email"]
    pass = params["Passwd"] || params["password"]

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
      %{username: _} = operator ->
        fun.(operator, conn)

      nil ->
        Logger.warning("GReader auth failed path=#{Enum.join(conn.path_info, "/")}")
        text(conn, 401, "Error=AuthRequired")
    end
  end

  defp current_user(conn, params) do
    token =
      bearer_or_google(conn) ||
        params["Authorization"] ||
        params["auth"] ||
        params["T"] ||
        params["Auth"]

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

  # Require edit token on mutating endpoints. Accepts dedicated edit token
  # or the auth token in `T` (common client habit).
  defp require_edit_token(user, params) do
    token = params["T"] || params["t"]

    cond do
      is_binary(token) and token != "" and GReader.verify_edit_token(user, token) ->
        :ok

      is_binary(token) and token != "" and is_map(GReader.verify_auth(token)) ->
        :ok

      true ->
        :error
    end
  end

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
      continuation: params["c"],
      ot: params["ot"],
      nt: params["nt"],
      original: params["original"] == "1"
    ]
  end

  defp merge_params(conn) do
    body =
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> %{}
        %{} = m -> m
        _ -> %{}
      end

    Map.merge(body, conn.query_params)
  end

  # Collect every value for a repeated form/query key.
  # Plug's urlencoded decoder collapses `i=a&i=b` to just the last value.
  defp multi_param(conn, params, key) do
    from_raw =
      extract_all_values(conn.assigns[:raw_body], key) ++
        extract_all_values(conn.query_string, key)

    values =
      case from_raw do
        [] -> List.wrap(params[key])
        list -> list
      end

    values
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp extract_all_values(nil, _key), do: []
  defp extract_all_values("", _key), do: []

  defp extract_all_values(raw, key) when is_binary(raw) do
    raw
    |> String.split("&")
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] ->
          if URI.decode_www_form(k) == key do
            [URI.decode_www_form(v)]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp extract_all_values(_, _), do: []

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
