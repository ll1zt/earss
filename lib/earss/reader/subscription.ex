defmodule Earss.Reader.Subscription do
  @moduledoc """
  The operator's subscription to one `Feed`, with per-source overrides.

  `custom_title` and `custom_refresh_interval` override the feed-level
  defaults; `is_hidden` excludes a subscription from the "all" view and from
  refresh-interval aggregation (decision D1) without dropping the feed.

  `unread_count` is virtual — populated by the listing queries, never
  persisted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "subscriptions" do
    field :custom_title, :string
    field :custom_refresh_interval, :integer
    field :is_hidden, :boolean, default: false
    field :unread_count, :integer, virtual: true

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
      :feed_id,
      :category_id
    ])
    |> validate_required([:feed_id])
    |> validate_number(:custom_refresh_interval, greater_than: 0)
    |> assoc_constraint(:feed)
    |> assoc_constraint(:category)
    |> unique_constraint(:feed_id)
  end
end
