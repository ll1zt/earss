defmodule Earss.Reader.EntryState do
  use Ecto.Schema
  import Ecto.Changeset

  schema "entry_states" do
    field :is_read, :boolean, default: false
    field :is_star, :boolean, default: false
    field :read_at, :utc_datetime

    belongs_to :entry, Earss.Feeds.Entry

    timestamps(type: :utc_datetime)
  end

  def changeset(entry_state, attrs) do
    entry_state
    |> cast(attrs, [:is_read, :is_star, :read_at, :entry_id])
    |> validate_required([:entry_id])
    |> put_read_at()
    |> assoc_constraint(:entry)
    |> unique_constraint(:entry_id)
  end

  # Keep DB check satisfied: unread => nil read_at; read => non-nil read_at.
  defp put_read_at(changeset) do
    is_read = get_field(changeset, :is_read)

    cond do
      is_read == false ->
        put_change(changeset, :read_at, nil)

      is_read == true and is_nil(get_field(changeset, :read_at)) ->
        put_change(changeset, :read_at, DateTime.utc_now() |> DateTime.truncate(:second))

      true ->
        changeset
    end
  end
end
