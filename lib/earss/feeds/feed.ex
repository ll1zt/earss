defmodule Earss.Feeds.Feed do
  use Ecto.Schema
  import Ecto.Changeset

  @feed_types ~w(rss atom json)

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
    field :max_refresh_interval, :integer, default: 10_080
    field :unchanged_fetch_count, :integer, default: 0
    field :error_count, :integer, default: 0
    field :last_error, :string
    field :etag, :string
    field :last_modified, :string
    field :last_fetched_content_hash, :string
    field :is_active, :boolean, default: true
    field :last_unsubscribed_at, :utc_datetime
    field :last_new_entry_at, :utc_datetime

    has_many :entries, Earss.Feeds.Entry
    has_many :subscriptions, Earss.Reader.Subscription

    timestamps(type: :utc_datetime)
  end

  def feed_types, do: @feed_types

  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :link,
      :feed_type,
      :site_url,
      :title,
      :description,
      :last_fetched_at,
      :next_fetch_at,
      :refresh_interval,
      :min_refresh_interval,
      :max_refresh_interval,
      :unchanged_fetch_count,
      :error_count,
      :last_error,
      :etag,
      :last_modified,
      :last_fetched_content_hash,
      :is_active,
      :last_unsubscribed_at,
      :last_new_entry_at
    ])
    |> validate_required([:link])
    |> validate_inclusion(:feed_type, @feed_types)
    |> validate_number(:refresh_interval, greater_than: 0)
    |> validate_number(:min_refresh_interval, greater_than: 0)
    |> validate_number(:max_refresh_interval, greater_than: 0)
    |> validate_number(:unchanged_fetch_count, greater_than_or_equal_to: 0)
    |> validate_number(:error_count, greater_than_or_equal_to: 0)
    |> validate_interval_bounds()
    |> unique_constraint(:link)
  end

  defp validate_interval_bounds(changeset) do
    min = get_field(changeset, :min_refresh_interval)
    max = get_field(changeset, :max_refresh_interval)
    refresh = get_field(changeset, :refresh_interval)

    changeset =
      if is_integer(min) and is_integer(max) and max < min do
        add_error(changeset, :max_refresh_interval, "must be greater than or equal to min_refresh_interval")
      else
        changeset
      end

    if is_integer(min) and is_integer(max) and is_integer(refresh) and
         (refresh < min or refresh > max) do
      add_error(changeset, :refresh_interval, "must be between min and max refresh interval")
    else
      changeset
    end
  end
end
