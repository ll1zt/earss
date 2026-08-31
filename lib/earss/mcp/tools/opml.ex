defmodule Earss.MCP.Tools.Opml do
  @moduledoc """
  OPML tools: the subscription list as a portable document.

  Export is a plain read. Import is destructive — it creates one
  subscription per outline (each of which the operator would have to remove
  individually) and can trigger a crawl per new feed — so it reports the
  document's shape first and needs `confirm: true` to go through.
  """

  alias Earss.MCP.Tool
  alias Earss.Reader

  @default_refresh false

  @doc """
  Every tool this module contributes.
  """
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new(
        name: "opml_export",
        description:
          "Export every subscription as an OPML XML document (the standard " <>
            "feed-list format any RSS reader understands).",
        input_schema: %{
          type: "object",
          properties: %{
            include_hidden: %{type: "boolean", description: "Include hidden subscriptions"}
          },
          additionalProperties: false
        },
        mutating: false,
        handler: &opml_export/1
      ),
      Tool.new(
        name: "opml_import",
        description:
          "Import subscriptions from an OPML XML document. Already-subscribed " <>
            "feeds are skipped, so re-importing is safe. Destructive: it " <>
            "creates one subscription per outline — call once to preview the " <>
            "document, then again with confirm: true to import.",
        input_schema: %{
          type: "object",
          properties: %{
            opml: %{type: "string", description: "The OPML XML document"},
            refresh: %{
              type: "boolean",
              description:
                "Fetch each newly imported feed right away (default false; the " <>
                  "poller picks them up anyway)"
            },
            confirm: %{
              type: "boolean",
              description: "Set true to actually import. Without it only a preview is returned."
            }
          },
          required: ["opml"],
          additionalProperties: false
        },
        mutating: true,
        destructive: true,
        impact: &import_impact/1,
        handler: &opml_import/1
      )
    ]
  end

  ## Handlers

  defp opml_export(args) do
    case Reader.export_opml(include_hidden: Map.get(args, "include_hidden") == true) do
      {:ok, xml} -> {:ok, %{opml: xml, byte_size: byte_size(xml)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp opml_import(%{"opml" => xml} = args) when is_binary(xml) do
    opts = [refresh: Map.get(args, "refresh", @default_refresh) == true]

    case Reader.import_opml(xml, opts) do
      {:ok, stats} -> {:ok, Map.put(stats, :executed, true)}
      {:error, reason} -> {:error, format_parse_error(reason)}
    end
  end

  defp opml_import(_), do: {:error, "opml is required and must be the XML document as a string"}

  ## Confirmation-phase preview

  defp import_impact(%{"opml" => xml}) when is_binary(xml) do
    case Earss.Reader.OPML.parse(xml) do
      {:ok, items} ->
        by_category =
          items
          |> Enum.group_by(& &1.category)
          |> Map.new(fn {cat, list} -> {cat || "(uncategorised)", length(list)} end)

        %{
          affected: :subscriptions,
          outlines: length(items),
          by_category: by_category,
          links: Enum.map(items, & &1.link)
        }

      {:error, reason} ->
        %{affected: :none, parse_error: inspect(reason)}
    end
  end

  defp import_impact(_), do: %{}

  defp format_parse_error(reason), do: "could not parse OPML: #{inspect(reason)}"
end
