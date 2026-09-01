defmodule Earss.MCP.Tools.Categories do
  @moduledoc """
  Category tools: how an agent organises subscriptions into folders.

  Creation, rename and reposition are ordinary writes. Deleting is
  destructive in a quiet way — nothing is lost, but every subscription in
  the category silently falls back to uncategorised — so it runs in the
  two-phase confirm flow and reports how many subscriptions are affected.
  """

  alias Earss.MCP.Tool
  alias Earss.Reader
  alias Earss.Repo

  @max_name_length 100

  @doc """
  Every tool this module contributes.
  """
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new(
        name: "category_list",
        description: "List your categories with how many subscriptions each holds.",
        mutating: false,
        handler: &category_list/1
      ),
      Tool.new(
        name: "category_create",
        description: "Create a category (a folder for subscriptions).",
        input_schema: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "Category name (unique, max #{@max_name_length})"
            },
            position: %{type: "integer", description: "Display order (default: last)"}
          },
          required: ["name"],
          additionalProperties: false
        },
        mutating: true,
        handler: &category_create/1
      ),
      Tool.new(
        name: "category_update",
        description: "Rename a category or change its display position.",
        input_schema: %{
          type: "object",
          properties: %{
            id: %{type: "integer", description: "Category id"},
            name: %{type: "string", description: "New name"},
            position: %{type: "integer", description: "New display position"}
          },
          required: ["id"],
          additionalProperties: false
        },
        mutating: true,
        handler: &category_update/1
      ),
      Tool.new(
        name: "category_delete",
        description:
          "Delete a category. Its subscriptions are kept but become " <>
            "uncategorised. Destructive: call it once to see what is in the " <>
            "category, then again with confirm: true to delete it.",
        input_schema: %{
          type: "object",
          properties: %{
            id: %{type: "integer", description: "Category id"},
            confirm: %{
              type: "boolean",
              description:
                "Set true to actually delete. Without it the tool only reports " <>
                  "what is inside the category."
            }
          },
          required: ["id"],
          additionalProperties: false
        },
        mutating: true,
        destructive: true,
        impact: &delete_impact/1,
        handler: &category_delete/1
      )
    ]
  end

  ## Handlers

  defp category_list(_args) do
    cats = Reader.list_categories()
    counts = subscription_counts()

    {:ok,
     %{
       categories:
         Enum.map(cats, fn c ->
           %{
             id: c.id,
             name: c.name,
             position: c.position,
             subscriptions: Map.get(counts, c.id, 0)
           }
         end),
       count: length(cats)
     }}
  end

  defp category_create(%{"name" => name} = args) when is_binary(name) do
    attrs = %{"name" => String.trim(name)} |> maybe_int("position", args["position"])

    case Reader.create_category(attrs) do
      {:ok, cat} -> {:ok, %{category: %{id: cat.id, name: cat.name, position: cat.position}}}
      {:error, %Ecto.Changeset{} = cs} -> {:error, Tool.format_changeset(cs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp category_create(_), do: {:error, "name is required and must be a string"}

  defp category_update(%{"id" => id} = args) when is_integer(id) do
    with {:ok, cat} <- fetch_category(id) do
      attrs =
        %{}
        |> maybe_str("name", args["name"] && String.trim(args["name"]))
        |> maybe_int("position", args["position"])

      if map_size(attrs) == 0 do
        {:error, "nothing to update: pass name or position"}
      else
        case Reader.update_category(cat, attrs) do
          {:ok, updated} ->
            {:ok, %{category: %{id: updated.id, name: updated.name, position: updated.position}}}

          {:error, %Ecto.Changeset{} = cs} ->
            {:error, Tool.format_changeset(cs)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp category_update(_), do: {:error, "id is required and must be an integer"}

  defp category_delete(%{"id" => id}) when is_integer(id) do
    with {:ok, cat} <- fetch_category(id) do
      case Reader.delete_category(cat) do
        {:ok, _} -> {:ok, %{id: id, deleted: true, name: cat.name}}
        {:error, %Ecto.Changeset{} = cs} -> {:error, Tool.format_changeset(cs)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp category_delete(_), do: {:error, "id is required and must be an integer"}

  ## Confirmation-phase report for the destructive delete

  defp delete_impact(%{"id" => id}) when is_integer(id) do
    case Reader.get_category(id) do
      nil ->
        %{affected: :none, reason: "no category #{id}"}

      cat ->
        subs = subscription_count(id)

        %{
          affected: :category,
          id: id,
          name: cat.name,
          subscriptions_to_uncategorise: subs
        }
    end
  end

  defp delete_impact(_), do: %{}

  ## Helpers

  defp fetch_category(id) do
    case Reader.get_category(id) do
      nil -> {:error, "no category #{id}"}
      cat -> {:ok, cat}
    end
  end

  defp subscription_count(category_id) do
    import Ecto.Query

    Earss.Reader.Subscription
    |> where([s], s.category_id == ^category_id)
    |> select([s], count(s.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp subscription_counts do
    import Ecto.Query

    Earss.Reader.Subscription
    |> group_by([s], s.category_id)
    |> select([s], {s.category_id, count(s.id)})
    |> Repo.all()
    |> Map.new(fn {id, n} -> {id, n} end)
  end

  defp maybe_str(map, _key, nil), do: map
  defp maybe_str(map, _key, ""), do: map
  defp maybe_str(map, key, v) when is_binary(v), do: Map.put(map, key, v)
  defp maybe_str(map, _key, _), do: map

  defp maybe_int(map, _key, nil), do: map
  defp maybe_int(map, key, v) when is_integer(v), do: Map.put(map, key, v)
  defp maybe_int(map, _key, _), do: map
end
