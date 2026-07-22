defmodule Earss.Reader.User do
  use Ecto.Schema
  import Ecto.Changeset

  @user_types ~w(admin sub_user)

  schema "users" do
    field :username, :string
    field :password_hash, :string
    field :user_type, :string, default: "admin"
    field :is_active, :boolean, default: true

    has_many :categories, Earss.Reader.Category
    has_many :subscriptions, Earss.Reader.Subscription
    has_many :entry_states, Earss.Reader.EntryState

    timestamps(type: :utc_datetime)
  end

  def user_types, do: @user_types

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password_hash, :user_type, :is_active])
    |> update_change(:username, &normalize_username/1)
    |> validate_required([:username, :password_hash])
    |> validate_length(:username, min: 1, max: 64)
    |> validate_inclusion(:user_type, @user_types)
    |> unique_constraint(:username)
  end

  defp normalize_username(nil), do: nil
  defp normalize_username(username) when is_binary(username), do: String.trim(username)
  defp normalize_username(other), do: other
end
