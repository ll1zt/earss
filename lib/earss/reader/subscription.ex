defmodule Earss.Reader.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @lang_tag ~r/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/
  @original_layouts ~w(off inline section interleaved)

  schema "subscriptions" do
    field :custom_title, :string
    field :custom_refresh_interval, :integer
    field :is_hidden, :boolean, default: false
    field :translate_to, :string
    field :return_original, :boolean, default: true
    field :original_layout, :string, default: "inline"
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
      :translate_to,
      :return_original,
      :original_layout,
      :user_id,
      :feed_id,
      :category_id
    ])
    |> validate_required([:user_id, :feed_id])
    |> validate_number(:custom_refresh_interval, greater_than: 0)
    |> validate_format(:translate_to, @lang_tag,
      message: "must be a language tag like 'zh' or 'zh-CN'"
    )
    |> validate_inclusion(:original_layout, @original_layouts)
    |> assoc_constraint(:user)
    |> assoc_constraint(:feed)
    |> assoc_constraint(:category)
    |> unique_constraint([:user_id, :feed_id])
  end
end
