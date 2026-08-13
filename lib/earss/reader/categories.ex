defmodule Earss.Reader.Categories do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Earss.Repo
  alias Earss.Reader.Category
  alias Earss.Reader.AnchorUser

  def list_categories do
    Category
    |> where([c], c.user_id == ^AnchorUser.id())
    |> order_by([c], asc: c.position, asc: c.id)
    |> Repo.all()
  end

  def get_category(id), do: Repo.get(Category, id)

  def create_category(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("user_id", AnchorUser.id())

    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert()
  end

  def update_category(%Category{} = category, attrs) when is_map(attrs) do
    category
    |> Category.changeset(stringify_keys(attrs))
    |> Repo.update()
  end

  def delete_category(%Category{} = category), do: Repo.delete(category)

  @doc false
  def ensure_category(name) when is_binary(name) do
    name = String.trim(name)

    case Enum.find(list_categories(), &(String.downcase(&1.name) == String.downcase(name))) do
      nil -> create_category(%{name: name})
      cat -> {:ok, cat}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
    end)
  end
end
