defmodule Earss.Reader.EntryState do
  use Ecto.Schema
  import Ecto.Changeset

  schema "entry_states" do
    field :is_read, :boolean, default: false
    field :is_star, :boolean, default: false
    field :read_at, :utc_datetime

    belongs_to :user, Earss.Reader.User
    belongs_to :entry, Earss.Feeds.Entry

    timestamps()
  end

  def changeset(entry_state, attrs) do
    entry_state
    |> cast(attrs, [:is_read, :is_star, :read_at, :user_id, :entry_id])
    |> validate_required([:user_id, :entry_id])
    |> unique_constraint([:user_id, :entry_id])
  end
end
