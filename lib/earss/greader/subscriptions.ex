defmodule Earss.GReader.Subscriptions do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Reader
  alias Earss.Reader.User
  alias Earss.Reader.Subscription
  alias Earss.Feeds
  alias Earss.Feeds.Entry
  alias Earss.Feeds.Feed
  alias Earss.Reader.EntryState
  alias Earss.Reader.Category
  alias Earss.GReader.Ids
  alias Earss.GReader.Streams

  def subscription_list(%User{} = user) do
    subs = Reader.list_subscriptions(user, include_hidden: false, with_unread_count: true)

    subscriptions =
      Enum.with_index(subs, fn sub, idx ->
        feed = sub.feed
        title = sub.custom_title || feed.title || feed.link

        %{
          "id" => Ids.feed_stream_id(feed),
          "title" => title,
          "categories" => feed_categories(sub),
          "url" => feed.link,
          "htmlUrl" => feed.site_url || feed.link,
          "iconUrl" => "",
          "sortid" => Ids.sortid(idx + 1)
        }
      end)

    %{"subscriptions" => subscriptions}
  end

  defp feed_categories(%{category: %Category{} = c}) do
    [%{"id" => Ids.label_stream_id(c.name), "label" => c.name}]
  end

  defp feed_categories(_), do: []

  ## Tag list

  def tag_list(%User{} = user) do
    cats = Reader.list_categories(user)

    # Match FreshRSS: system tags first, then folders with type=folder.
    # NNW FreshRSS accounts create sidebar folders from tags containing "/label/".
    tags =
      [
        %{"id" => "user/-/state/com.google/starred"},
        %{"id" => "user/-/state/com.google/reading-list"}
      ] ++
        Enum.map(cats, fn c ->
          %{
            "id" => Ids.label_stream_id(c.name),
            "type" => "folder"
          }
        end)

    %{"tags" => tags}
  end

  ## User info

  def user_info(%User{} = user) do
    %{
      "userId" => to_string(user.id),
      "userName" => user.username,
      "userProfileId" => to_string(user.id),
      "userEmail" => user.username,
      "isBloggerUser" => false,
      "signupTimeSec" => unix(user.inserted_at) || 0,
      "isMultiLoginEnabled" => false
    }
  end

  @doc """
  Unread counts for NetNewsWire / FreshRSS (`reader/api/0/unread-count`).

  Returns per-feed counts, per-label counts, and reading-list total.
  """
  def unread_count(%User{} = user) do
    subs = Reader.list_subscriptions(user, include_hidden: false, with_unread_count: true)
    by_feed = Reader.unread_counts_by_feed(user)

    feed_counts =
      Enum.map(subs, fn sub ->
        count = Map.get(by_feed, sub.feed_id, sub.unread_count || 0)

        %{
          "id" => Ids.feed_stream_id(sub.feed),
          "count" => count,
          "newestItemTimestampUsec" => newest_usec(user, sub.feed_id)
        }
      end)

    label_counts =
      subs
      |> Enum.group_by(fn s -> s.category && s.category.name end)
      |> Enum.reject(fn {name, _} -> is_nil(name) end)
      |> Enum.map(fn {name, group_subs} ->
        count =
          group_subs
          |> Enum.map(&Map.get(by_feed, &1.feed_id, &1.unread_count || 0))
          |> Enum.sum()

        %{
          "id" => Ids.label_stream_id(name),
          "count" => count,
          "newestItemTimestampUsec" => "0"
        }
      end)

    total =
      feed_counts
      |> Enum.map(& &1["count"])
      |> Enum.sum()

    newest =
      feed_counts
      |> Enum.map(& &1["newestItemTimestampUsec"])
      |> Enum.reject(&(&1 in [nil, "0"]))
      |> Enum.max(fn -> "0" end)

    reading_list_ids = [
      "user/-/state/com.google/reading-list",
      "user/#{user.id}/state/com.google/reading-list"
    ]

    reading_list =
      Enum.map(reading_list_ids, fn id ->
        %{
          "id" => id,
          "count" => total,
          "newestItemTimestampUsec" => newest
        }
      end)

    %{
      "max" => 1000,
      "unreadcounts" => reading_list ++ feed_counts ++ label_counts
    }
  end

  defp newest_usec(%User{id: user_id}, feed_id) do
    # Prefer inserted_at (when we ingested) over publisher's published_at.
    # Feeds often backdate published_at years; NNW may treat that as "no recent items"
    # and show unread 0 even when unread-count is non-zero.
    case from(e in Entry,
           join: s in Subscription,
           on: s.feed_id == e.feed_id and s.user_id == ^user_id,
           left_join: st in EntryState,
           on: st.entry_id == e.id and st.user_id == ^user_id,
           where: e.feed_id == ^feed_id,
           where: is_nil(st.id) or st.is_read == false,
           order_by: [desc: e.inserted_at, desc: e.id],
           limit: 1,
           select: {e.inserted_at, e.published_at}
         )
         |> Repo.one() do
      nil ->
        "0"

      {ins, pub} ->
        dt = later_dt(ins, pub) || ins || pub

        case dt do
          %DateTime{} = d -> "#{DateTime.to_unix(d)}000000"
          _ -> "0"
        end
    end
  end

  defp later_dt(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end

  defp later_dt(%DateTime{} = a, _), do: a
  defp later_dt(_, %DateTime{} = b), do: b
  defp later_dt(_, _), do: nil

  def subscription_edit(%User{} = user, params) when is_map(params) do
    params = stringify_param_keys(params)
    ac = params["ac"] || params["action"] || ""
    stream = params["s"]
    title = blank_to_nil(params["t"])
    add_label = params["a"]
    remove_label = params["r"]

    case ac do
      "subscribe" ->
        do_subscribe_edit(user, stream, title, add_label)

      "edit" ->
        do_edit_subscription(user, stream, title, add_label, remove_label)

      "unsubscribe" ->
        do_unsubscribe(user, stream)

      _ ->
        {:error, :bad_request}
    end
  end

  defp do_subscribe_edit(user, stream, title, add_label) do
    with {:ok, attrs} <- subscribe_attrs_from_stream(user, stream, title, add_label) do
      # Queue via next_fetch_at; avoid blocking the HTTP request on a live crawl.
      case Reader.subscribe(user, Map.put(attrs, "refresh", false)) do
        {:ok, _} -> :ok
        {:error, %Ecto.Changeset{}} = err -> err
        {:error, :not_found} -> {:error, :not_found}
        {:error, _} = err -> err
      end
    end
  end

  defp do_edit_subscription(user, stream, title, add_label, remove_label) do
    case Streams.feed_from_stream(user, normalize_feed_stream(stream)) do
      %Feed{id: feed_id} ->
        case Reader.get_subscription(user, feed_id) do
          %Subscription{} = sub ->
            attrs = %{}
            attrs = if title, do: Map.put(attrs, "custom_title", title), else: attrs

            attrs =
              cond do
                is_binary(add_label) and String.contains?(add_label, "/label/") ->
                  label = Ids.label_from_stream(add_label)

                  case ensure_category(user, label) do
                    {:ok, %Category{id: cid}} -> Map.put(attrs, "category_id", cid)
                    _ -> attrs
                  end

                is_binary(remove_label) and String.contains?(remove_label, "/label/") ->
                  Map.put(attrs, "category_id", nil)

                true ->
                  attrs
              end

            case Reader.update_subscription(sub, attrs) do
              {:ok, _} -> :ok
              error -> error
            end

          nil ->
            # FreshRSS clients sometimes use edit as upsert subscribe.
            do_subscribe_edit(user, stream, title, add_label)
        end

      nil ->
        do_subscribe_edit(user, stream, title, add_label)
    end
  end

  defp do_unsubscribe(user, stream) do
    stream = normalize_feed_stream(stream)

    feed_id =
      case Streams.feed_from_stream(user, stream) do
        %Feed{id: id} ->
          id

        nil ->
          case stream do
            "feed/" <> rest ->
              rest = URI.decode(rest)

              case Integer.parse(rest) do
                {id, ""} -> id
                _ -> Feeds.get_feed_by_link(rest) && Feeds.get_feed_by_link(rest).id
              end

            _ ->
              nil
          end
      end

    if feed_id do
      case Reader.unsubscribe(user, feed_id) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        error -> error
      end
    else
      {:error, :not_found}
    end
  end

  defp subscribe_attrs_from_stream(user, stream, title, add_label) do
    stream = normalize_feed_stream(stream)

    base =
      case stream do
        "feed/" <> rest ->
          rest = URI.decode(rest)

          case Integer.parse(rest) do
            {id, ""} ->
              %{"feed_id" => id}

            _ ->
              %{"link" => rest}
          end

        other when is_binary(other) and other != "" ->
          %{"link" => other}

        _ ->
          nil
      end

    cond do
      is_nil(base) ->
        {:error, :bad_request}

      true ->
        attrs = maybe_put_title(base, title)

        attrs =
          case category_id_from_label(user, add_label) do
            {:ok, cid} -> Map.put(attrs, "category_id", cid)
            :none -> attrs
            {:error, _} = err -> err
          end

        case attrs do
          {:error, _} = err -> err
          map when is_map(map) -> {:ok, map}
        end
    end
  end

  defp maybe_put_title(attrs, nil), do: attrs

  defp maybe_put_title(attrs, title) do
    attrs
    |> Map.put("title", title)
    |> Map.put("custom_title", title)
  end

  defp category_id_from_label(_user, label) when label in [nil, ""], do: :none

  defp category_id_from_label(user, label) when is_binary(label) do
    if String.contains?(label, "/label/") do
      name = Ids.label_from_stream(label)

      case ensure_category(user, name) do
        {:ok, %Category{id: cid}} -> {:ok, cid}
        {:error, _} = err -> err
      end
    else
      :none
    end
  end

  defp category_id_from_label(_, _), do: :none

  defp normalize_feed_stream(nil), do: nil

  defp normalize_feed_stream(stream) when is_binary(stream) do
    stream = stream |> URI.decode() |> String.trim()

    cond do
      String.starts_with?(stream, "feed/") -> stream
      String.match?(stream, ~r{^https?://}i) -> "feed/#{stream}"
      true -> stream
    end
  end

  defp ensure_category(user, name), do: Earss.Reader.Categories.ensure_category(user, name)

  defp stringify_param_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp unix(nil), do: nil
  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp unix(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
end
