defmodule Earss.Admin.Views.Settings do
  @moduledoc false

  alias Earss.Admin.HTML
  alias Earss.OperatorAuth

  def page(operator, flash, fever_url) do
    fever_key = OperatorAuth.fever_api_key()
    fever_set? = is_binary(fever_key) and fever_key != ""

    key_short =
      cond do
        fever_set? and byte_size(fever_key) > 12 ->
          String.slice(fever_key, 0, 8) <> "…" <> String.slice(fever_key, -4, 4)

        fever_set? ->
          fever_key

        true ->
          "(not set)"
      end

    inner = """
    <div class="card">
      <h2>Fever / NetNewsWire</h2>
      <p>URL: <code>#{HTML.h(fever_url)}</code></p>
      <p class="muted">
        Credentials come from the operator environment (single-operator mode):
        <code>FEVER_API_KEY</code> in <code>earss.env</code>.
        Configure it there and restart the app.
      </p>
      <p class="muted">Configured api key: <code>#{HTML.h(key_short)}</code></p>
    </div>
    <div class="card">
      <h2>Login password</h2>
      <p class="muted">
        The admin login uses <code>ADMIN_PASSWORD</code> from
        <code>earss.env</code> (or the environment). Change it there and
        restart the app — passwords are no longer stored in the database.
      </p>
    </div>
    """

    HTML.shell(operator, flash, "Settings", inner, active: "settings")
  end
end
