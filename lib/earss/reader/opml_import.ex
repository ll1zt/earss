defmodule Earss.Reader.OPMLImport do
  @moduledoc false

  alias Earss.Reader.Categories
  alias Earss.Reader.OPML
  alias Earss.Reader.Subscriptions

  @doc """
  Import OPML for the operator. Creates categories by outline folders when
  present.

  Options:
    * `:refresh` — default `false` (let poller fetch)
  """
  def import_opml(xml, opts \\ []) when is_binary(xml) do
    refresh? = Keyword.get(opts, :refresh, false)

    case OPML.parse(xml) do
      {:error, reason} ->
        {:error, reason}

      {:ok, items} ->
        results =
          Enum.map(items, fn item ->
            category_id =
              case item.category do
                nil ->
                  nil

                name ->
                  case Categories.ensure_category(name) do
                    {:ok, cat} -> cat.id
                    _ -> nil
                  end
              end

            attrs = %{
              "link" => item.link,
              "title" => item.title,
              "category_id" => category_id,
              "refresh" => refresh?
            }

            case Subscriptions.subscribe(attrs) do
              {:ok, sub} -> {:ok, sub}
              {:error, %Ecto.Changeset{}} -> {:skipped, :already_subscribed}
              {:error, reason} -> {:error, reason}
            end
          end)

        %{
          total: length(items),
          imported: Enum.count(results, &match?({:ok, _}, &1)),
          skipped: Enum.count(results, &match?({:skipped, _}, &1)),
          errors: Enum.count(results, &match?({:error, _}, &1))
        }
        |> then(&{:ok, &1})
    end
  end

  @doc """
  Export the operator's subscriptions as OPML XML.
  """
  def export_opml(opts \\ []) do
    include_hidden? = Keyword.get(opts, :include_hidden, false)

    items =
      Subscriptions.list_subscriptions(include_hidden: include_hidden?)
      |> Enum.map(fn sub ->
        title = sub.custom_title || (sub.feed && sub.feed.title) || sub.feed.link
        category = if sub.category, do: sub.category.name, else: nil

        %{
          title: title,
          link: sub.feed.link,
          site_url: sub.feed.site_url,
          category: category
        }
      end)

    {:ok, OPML.export(items, "Earss subscriptions")}
  end
end
