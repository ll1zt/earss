defmodule Earss.Reader.Category do
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    field :position, :integer, default: 0

    has_many :subscriptions, Earss.Reader.Subscription

    timestamps(type: :utc_datetime)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :position])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end

  defp normalize_name(nil), do: nil
  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(other), do: other
end
