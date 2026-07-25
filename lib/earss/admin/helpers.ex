defmodule Earss.Admin.Helpers do
  @moduledoc false

  import Plug.Conn

  alias Earss.Admin.HTML
  alias Earss.Feeds.Feed

  def html(conn, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
  end

  def redirect(conn, path) do
    conn
    |> put_resp_header("location", path)
    |> send_resp(302, "")
  end

  def flash(conn), do: conn.assigns[:flash]

  def put_flash(conn, type, msg) do
    put_session(conn, :admin_flash, {type, msg})
  end

  def fetch_flash_assign(conn, _opts) do
    {flash, conn} =
      case get_session(conn, :admin_flash) do
        nil ->
          {nil, conn}

        f ->
          {f, delete_session(conn, :admin_flash)}
      end

    assign(conn, :flash, flash)
  end

  def bp(conn, key) do
    case conn.body_params do
      %{} = m -> Map.get(m, key)
      _ -> nil
    end
  end

  def empty_to_nil(nil), do: nil
  def empty_to_nil(""), do: nil
  def empty_to_nil(v), do: v

  def parse_int(nil), do: nil
  def parse_int(i) when is_integer(i), do: i

  def parse_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def parse_int(_), do: nil

  def format_error(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  def format_error(reason) when is_atom(reason), do: to_string(reason)
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  def referer_or(conn, default) do
    case get_req_header(conn, "referer") do
      [ref | _] ->
        uri = URI.parse(ref)

        if is_binary(uri.path) and String.starts_with?(uri.path, "/admin") do
          uri.path <> if(uri.query, do: "?" <> uri.query, else: "")
        else
          default
        end

      _ ->
        default
    end
  end

  def base_url(scheme, host, port) do
    if port in [80, 443] do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  def on_off(true), do: "on"
  def on_off(_), do: "off"

  def utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def display_title(sub) do
    sub.custom_title || (sub.feed && (sub.feed.title || sub.feed.link)) || "subscription ##{sub.id}"
  end

  def due_feed?(%Feed{next_fetch_at: nil}, _now), do: true

  def due_feed?(%Feed{next_fetch_at: next}, now) do
    DateTime.compare(next, now) != :gt
  end

  def due_feed?(_, _), do: false

  def filter_subs_q(subs, nil), do: subs

  def filter_subs_q(subs, q) do
    q = String.downcase(q)

    Enum.filter(subs, fn s ->
      title = String.downcase(display_title(s) || "")
      link = String.downcase((s.feed && s.feed.link) || "")
      String.contains?(title, q) or String.contains?(link, q)
    end)
  end

  def filter_subs_category(subs, nil), do: subs
  def filter_subs_category(subs, ""), do: subs

  def filter_subs_category(subs, "none") do
    Enum.filter(subs, &is_nil(&1.category_id))
  end

  def filter_subs_category(subs, cat_id) do
    case parse_int(cat_id) do
      nil -> subs
      id -> Enum.filter(subs, &(&1.category_id == id))
    end
  end

  def filter_subs_status(subs, "all", _now), do: subs
  def filter_subs_status(subs, "visible", _now), do: Enum.reject(subs, & &1.is_hidden)
  def filter_subs_status(subs, "hidden", _now), do: Enum.filter(subs, & &1.is_hidden)

  def filter_subs_status(subs, "error", _now) do
    Enum.filter(subs, fn s ->
      f = s.feed
      f && f.is_active && is_integer(f.error_count) && f.error_count > 0
    end)
  end

  def filter_subs_status(subs, "disabled", _now) do
    Enum.filter(subs, fn s -> s.feed && s.feed.is_active == false end)
  end

  def filter_subs_status(subs, "due", now) do
    Enum.filter(subs, fn s -> s.feed && s.feed.is_active && due_feed?(s.feed, now) end)
  end

  def filter_subs_status(subs, _, _), do: subs

  def filter_feeds_status(subs, "all", _now), do: subs

  def filter_feeds_status(subs, "active", _now) do
    Enum.filter(subs, fn s -> s.feed && s.feed.is_active && s.feed.error_count == 0 end)
  end

  def filter_feeds_status(subs, "disabled", _now) do
    Enum.filter(subs, fn s -> s.feed && s.feed.is_active == false end)
  end

  def filter_feeds_status(subs, "error", _now) do
    Enum.filter(subs, fn s ->
      f = s.feed
      f && (f.is_active == false || (is_integer(f.error_count) && f.error_count > 0))
    end)
  end

  def filter_feeds_status(subs, "due", now) do
    Enum.filter(subs, fn s -> s.feed && s.feed.is_active && due_feed?(s.feed, now) end)
  end

  def filter_feeds_status(subs, _, _), do: subs

  def sort_subs(subs, "unread") do
    Enum.sort_by(subs, fn s -> {-(s.unread_count || 0), s.id} end)
  end

  def sort_subs(subs, "next_fetch") do
    Enum.sort_by(subs, fn s ->
      next = s.feed && s.feed.next_fetch_at
      {is_nil(next), next, s.id}
    end)
  end

  def sort_subs(subs, "id") do
    Enum.sort_by(subs, & &1.id, :desc)
  end

  def sort_subs(subs, _) do
    Enum.sort_by(subs, fn s -> String.downcase(display_title(s) || "") end)
  end

  def category_options(cats, selected, opts \\ []) do
    include_all? = Keyword.get(opts, :include_all, false)

    head =
      cond do
        include_all? ->
          [
            option_tag("", "All categories", selected in [nil, ""]),
            option_tag("none", "— uncategorized —", selected == "none")
          ]

        true ->
          [option_tag("", "— none —", selected in [nil, ""])]
      end

    rest =
      Enum.map(cats, fn c ->
        option_tag(to_string(c.id), c.name, selected == to_string(c.id))
      end)

    Enum.join(head ++ rest, "")
  end

  def option_list(pairs, selected) do
    pairs
    |> Enum.map(fn {val, label} -> option_tag(val, label, selected == val) end)
    |> Enum.join("")
  end

  def option_tag(value, label, true) do
    ~s(<option value="#{HTML.h(value)}" selected>#{HTML.h(label)}</option>)
  end

  def option_tag(value, label, false) do
    ~s(<option value="#{HTML.h(value)}">#{HTML.h(label)}</option>)
  end
end
