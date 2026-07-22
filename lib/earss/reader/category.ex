defmodule Earss.Reader.Category do
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    field :position, :integer, default: 0

    belongs_to :user, Earss.Reader.User
    has_many :subscriptions, Earss.Reader.Subscription

    timestamps(type: :utc_datetime)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :position, :user_id])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name, :user_id])
    |> validate_length(:name, min: 1)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> assoc_constraint(:user)
    |> unique_constraint([:user_id, :name])
  end

  defp normalize_name(nil), do: nil
  defp normalize_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_name(other), do: other
end
