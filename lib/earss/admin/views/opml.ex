defmodule Earss.Admin.Views.OPML do
  @moduledoc false

  alias Earss.Admin.HTML

  def page(user, flash) do
    inner = """
    <div class="card">
      <h2>Export</h2>
      <p><a class="btn" href="/admin/opml/export">Download OPML</a></p>
    </div>
    <div class="card">
      <h2>Import</h2>
      <p class="muted">Paste OPML XML. Feeds are queued for the poller (no immediate refresh).</p>
      <form method="post" action="/admin/opml/import">#{HTML.csrf_input()}
        <textarea name="opml" required placeholder="&lt;opml ...&gt;"></textarea>
        <div><button type="submit">Import</button></div>
      </form>
    </div>
    """

    HTML.shell(user, flash, "OPML", inner, active: "opml")
  end
end
