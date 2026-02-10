defmodule Earss.Feed do
  use Ecto.Schema
  import Ecto.Changeset

  schema "feeds" do
    field :link, :string
    field :feed_type, :string, default: "rss"
    field :site_url, :string
    field :title, :string
    field :description, :string
    field :last_fetched_at, :utc_datetime
    field :next_fetch_at, :utc_datetime
    field :refresh_interval, :integer, default: 30
    field :min_refresh_interval, :integer, default: 15
    field :max_refresh_interval, :integer, default: 10080
    field :unchanged_fetch_count, :integer, default: 0
    field :error_count, :integer, default: 0
    field :last_error, :string
    field :etag, :string
    field :last_modified, :string
    field :last_fetched_content_hash, :string
    field :is_active, :boolean, default: true

    has_many :entries, Earss.Entry
    has_many :subscriptions, Earss.Subscription

    timestamps()
  end

  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :link, :feed_type, :site_url, :title, :description,
      :last_fetched_at, :next_fetch_at, :refresh_interval,
      :min_refresh_interval, :max_refresh_interval,
      :unchanged_fetch_count, :error_count, :last_error,
      :etag, :last_modified, :last_fetched_content_hash, :is_active
    ])
    |> validate_required([:link])
    |> unique_constraint(:link)
  end
end
