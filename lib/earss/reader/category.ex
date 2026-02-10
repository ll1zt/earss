defmodule Earss.Reader.Category do
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    
    belongs_to :user, Earss.Reader.User
    has_many :subscriptions, Earss.Reader.Subscription

    timestamps()
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :user_id])
    |> validate_required([:name, :user_id])
    |> unique_constraint([:user_id, :name])
  end
end
