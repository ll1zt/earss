defmodule Earss.Reader.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "subscriptions" do
    field :custom_title, :string
    field :custom_refresh_interval, :integer
    field :is_hidden, :boolean, default: false
    field :unread_count, :integer, virtual: true

    belongs_to :user, Earss.Reader.User
    belongs_to :feed, Earss.Feeds.Feed
    belongs_to :category, Earss.Reader.Category

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :custom_title,
      :custom_refresh_interval,
      :is_hidden,
      :user_id,
      :feed_id,
      :category_id
    ])
    |> validate_required([:user_id, :feed_id])
    |> validate_number(:custom_refresh_interval, greater_than: 0)
    |> assoc_constraint(:user)
    |> assoc_constraint(:feed)
    |> assoc_constraint(:category)
    |> unique_constraint([:user_id, :feed_id])
  end
end
