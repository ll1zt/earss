defmodule Earss.Admin.Views.Session do
  @moduledoc false

  alias Earss.Admin.HTML

  def login_page(flash, error \\ nil), do: HTML.login_page(flash, error)
end
