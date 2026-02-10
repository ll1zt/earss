defmodule Earss.Category do
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    
    belongs_to :user, Earss.User
    has_many :subscriptions, Earss.Subscription

    timestamps()
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :user_id])
    |> validate_required([:name, :user_id])
    |> unique_constraint([:user_id, :name])
  end
end
