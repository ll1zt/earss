defmodule Earss.Admin.Theme do
  @moduledoc false

  import Plug.Conn

  @themes ~w(crt paper)
  @default "crt"
  @process_key {__MODULE__, :current}

  def themes, do: @themes
  def default, do: @default

  @doc "Normalize theme id; unknown values fall back to default."
  def normalize(theme) when theme in @themes, do: theme
  def normalize("CRT"), do: "crt"
  def normalize("Paper"), do: "paper"
  def normalize(_), do: @default

  @doc "Plug: load theme from session into assigns and process dictionary for HTML."
  def fetch(conn, _opts \\ []) do
    theme =
      conn
      |> get_session(:admin_theme)
      |> normalize()

    Process.put(@process_key, theme)
    assign(conn, :admin_theme, theme)
  end

  @doc "Theme for the current request (defaults to crt)."
  def current do
    Process.get(@process_key, @default)
  end

  @doc "Persist theme in session and process dict."
  def put(conn, theme) do
    theme = normalize(theme)
    Process.put(@process_key, theme)

    conn
    |> put_session(:admin_theme, theme)
    |> assign(:admin_theme, theme)
  end

  def label("crt"), do: "CRT"
  def label("paper"), do: "Paper"
  def label(other), do: other
end
