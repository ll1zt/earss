defmodule Earss.Feeds.EntryTranslation do
  @moduledoc """
  One translated copy of an entry for one target language.

  Stored separately from `Earss.Feeds.Entry` so the shared original content
  is never mutated (Goal 2, docs/translate.md). `original_hash` records the
  entry's `content_hash` at translation time so re-translation can be skipped
  when content is unchanged; `model` records which provider/model produced it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @lang_tag ~r/^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/

  schema "entry_translations" do
    field :lang, :string
    field :title, :string
    field :summary, :string
    field :content, :string
    field :original_hash, :string
    field :model, :string
    field :translated_at, :utc_datetime

    belongs_to :entry, Earss.Feeds.Entry

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(translation, attrs) do
    translation
    |> cast(attrs, [
      :entry_id,
      :lang,
      :title,
      :summary,
      :content,
      :original_hash,
      :model,
      :translated_at
    ])
    |> validate_required([:entry_id, :lang, :translated_at])
    |> validate_format(:lang, @lang_tag, message: "must be a language tag like 'zh' or 'zh-CN'")
    |> assoc_constraint(:entry)
    |> unique_constraint([:entry_id, :lang])
  end
end
