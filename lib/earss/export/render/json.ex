defmodule Earss.Export.Render.JSON do
  @moduledoc false

  @doc """
  Opening JSON chunk: metadata fields plus the `"entries":[` prefix, **without**
  closing the outer object — the footer `"]}"` closes it, so the streamed
  document is one valid JSON object.
  """
  @spec head(keyword()) :: iodata()
  def head(opts) do
    scope = Jason.encode!(to_string(Keyword.get(opts, :scope, "export")))
    user = Jason.encode!(Keyword.get(opts, :user))
    generated = Jason.encode!(DateTime.utc_now() |> DateTime.truncate(:second))

    [~s({"scope":), scope, ~s(,"user":), user, ~s(,"generated":), generated, ~s(,"entries":[)]
  end

  @doc """
  One JSON object for an export row. `index` controls the leading comma
  between array items.
  """
  @spec row(map(), non_neg_integer()) :: iodata()
  def row(row, 0), do: Jason.encode!(row)
  def row(row, _index), do: [",", Jason.encode!(row)]
end
