defmodule Earss.MCP.Tools.ReadBatch do
  @moduledoc """
  Batch read-state tools.

  `entry_mark_read_batch` marks many entries read in one call, by explicit
  ids, by feed, or by category — optionally only those before a timestamp.
  This is the operation an agent reaches for constantly ("mark everything
  in this category read", "mark these search results read") and it exists to
  save the N round-trips that per-entry calls would cost.
  """

  alias Earss.MCP.Tool
  alias Earss.Reader

  @doc """
  Every tool this module contributes.
  """
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new(
        name: "entry_mark_read_batch",
        description:
          "Mark many articles read in one call. Select by explicit entry ids, " <>
            "by feed_id, or by category_id (everything in that folder); " <>
            "optionally restrict to articles published before a timestamp. " <>
            "Returns how many were marked. Exactly one of ids / feed_id / " <>
            "category_id is required.",
        input_schema: %{
          type: "object",
          properties: %{
            ids: %{type: "array", items: %{type: "integer"}, description: "Entry ids"},
            feed_id: %{type: "integer", description: "Mark every entry of this feed"},
            category_id: %{
              type: "integer",
              description: "Mark every entry of every subscription in this category"
            },
            before: %{
              type: "string",
              description: "ISO 8601 timestamp; only entries published before it are marked"
            }
          },
          oneOf: [
            %{required: ["ids"]},
            %{required: ["feed_id"]},
            %{required: ["category_id"]}
          ],
          additionalProperties: false
        },
        mutating: true,
        handler: &mark_read_batch/1
      )
    ]
  end

  defp mark_read_batch(args) do
    opts = build_opts(args)

    case Reader.mark_entries_read(opts) do
      {:ok, %{marked: marked}} ->
        {:ok, %{marked: marked, scope: scope(args)}}

      {:error, :not_found} ->
        {:error, "the feed or category has no subscription"}
    end
  end

  defp build_opts(args) do
    %{}
    |> put_ids(args["ids"])
    |> put_int(:feed_id, args["feed_id"])
    |> put_int(:category_id, args["category_id"])
    |> put_before(args["before"])
  end

  defp put_ids(opts, ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &is_integer/1), do: Map.put(opts, :ids, ids), else: opts
  end

  defp put_ids(opts, _), do: opts

  defp put_int(opts, key, n) when is_integer(n), do: Map.put(opts, key, n)
  defp put_int(opts, _key, _), do: opts

  defp put_before(opts, before) when is_binary(before) do
    case DateTime.from_iso8601(before) do
      {:ok, dt, _offset} ->
        # The facade's :before option is a unix timestamp in seconds, not a
        # DateTime (that is what Reader.EntryStates.normalize_unix accepts).
        Map.put(opts, :before, DateTime.to_unix(dt))

      _ ->
        opts
    end
  end

  defp put_before(opts, _), do: opts

  defp scope(%{"feed_id" => id}), do: %{type: :feed, feed_id: id}
  defp scope(%{"category_id" => id}), do: %{type: :category, category_id: id}
  defp scope(%{"ids" => ids}), do: %{type: :ids, count: length(ids)}
  defp scope(_), do: %{type: :unknown}
end
