defmodule Earss.TTS.Request do
  @moduledoc """
  A "listen to this article" request (TTS intent) for one entry.

  Idempotent on `entry_id` (unique index): repeated requests — a second
  click, an admin retry — converge on the same row. `state` starts at
  `"requested"` and is moved forward by the synthesis pipeline in later
  goals.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @states [:requested]

  schema "tts_requests" do
    field :state, Ecto.Enum, values: @states, default: :requested

    belongs_to :entry, Earss.Feeds.Entry

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:entry_id])
    |> validate_required([:entry_id])
    |> assoc_constraint(:entry)
    |> unique_constraint(:entry_id)
  end
end
