defmodule Earss.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :password_hash, :string
    field :user_type, :string, default: "admin"

    has_many :categories, Earss.Category
    has_many :subscriptions, Earss.Subscription
    has_many :entry_states, Earss.EntryState

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password_hash, :user_type])
    |> validate_required([:username, :password_hash])
    |> unique_constraint(:username)
  end
end
