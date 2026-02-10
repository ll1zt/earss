defmodule Earss.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "subscriptions" do
    field :custom_title, :string
    field :custom_refresh_interval, :integer
    field :is_hidden, :boolean, default: false

    belongs_to :user, Earss.User
    belongs_to :feed, Earss.Feed
    belongs_to :category, Earss.Category

    timestamps()
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:custom_title, :custom_refresh_interval, :is_hidden, :user_id, :feed_id, :category_id])
    |> validate_required([:user_id, :feed_id])
    |> unique_constraint([:user_id, :feed_id])
  end
end
