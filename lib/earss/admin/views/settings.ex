defmodule Earss.Admin.Views.Settings do
  @moduledoc false

  alias Earss.Admin.HTML

  def page(user, flash, fever_url) do
    key_preview = user.fever_api_key || "(not set — set password or Fever secret)"

    key_short =
      if is_binary(user.fever_api_key) and byte_size(user.fever_api_key) > 12 do
        String.slice(user.fever_api_key, 0, 8) <> "…" <> String.slice(user.fever_api_key, -4, 4)
      else
        key_preview
      end

    inner = """
    <div class="card">
      <h2>Fever / NetNewsWire</h2>
      <p>URL: <code>#{HTML.h(fever_url)}</code></p>
      <p>Username: <code>#{HTML.h(user.username)}</code></p>
      <p class="muted">Stored api_key fingerprint: <code>#{HTML.h(key_short)}</code></p>
      <form method="post" action="/admin/settings/fever">#{HTML.csrf_input()}
        <label>Fever-only password/secret (does not change login password)</label>
        <input name="fever_secret" type="password" autocomplete="new-password"/>
        <button type="submit">Set Fever secret</button>
      </form>
    </div>
    <div class="card">
      <h2>Login password</h2>
      <p class="muted">Also recomputes Fever api_key from username:new_password.</p>
      <form method="post" action="/admin/settings/password">#{HTML.csrf_input()}
        <label>New password</label>
        <input name="password" type="password" autocomplete="new-password" required/>
        <label>Confirm</label>
        <input name="password_confirm" type="password" autocomplete="new-password" required/>
        <button type="submit">Update password</button>
      </form>
    </div>
    """

    HTML.shell(user, flash, "Settings", inner, active: "settings")
  end
end
