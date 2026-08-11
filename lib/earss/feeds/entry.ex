defmodule Earss.Feeds.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "entries" do
    field :link, :string
    field :guid, :string
    field :title, :string
    field :author, :string
    field :summary, :string
    field :content, :string
    field :published_at, :utc_datetime
    field :content_hash, :string
    field :translation_pending_at, :utc_datetime
    field :translation_retry_count, :integer, default: 0

    belongs_to :feed, Earss.Feeds.Feed
    has_many :entry_states, Earss.Reader.EntryState
    has_many :translations, Earss.Feeds.EntryTranslation

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :link,
      :guid,
      :title,
      :author,
      :summary,
      :content,
      :published_at,
      :content_hash,
      :feed_id
    ])
    |> validate_required([:link, :guid, :feed_id])
    |> validate_length(:link, min: 1)
    |> validate_length(:guid, min: 1)
    |> assoc_constraint(:feed)
    |> unique_constraint([:feed_id, :guid])
  end
end
