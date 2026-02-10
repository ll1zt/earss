defmodule Earss.Entry do
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
    
    belongs_to :feed, Earss.Feed
    has_many :entry_states, Earss.EntryState

    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:link, :guid, :title, :author, :summary, :content, :published_at, :feed_id])
    |> validate_required([:link, :guid, :feed_id])
    |> unique_constraint([:feed_id, :guid])
  end
end
