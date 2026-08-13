defmodule Earss.Admin.Views.Export do
  @moduledoc false

  alias Earss.Admin.HTML

  def page(user, flash) do
    admin_block =
      """
      <div class="card">
        <h2>Full archive</h2>
        <p class="muted">Every entry stored on this instance, newest first. Markdown bodies are plain text (HTML stripped).</p>
        <div class="stack-actions">
          <a class="btn" href="/admin/export/all?format=markdown">Markdown</a>
          <a class="btn" href="/admin/export/all?format=json">JSON</a>
        </div>
      </div>
      """

    inner = """
    <div class="card">
      <h2>Starred entries</h2>
      <p class="muted">Your starred articles, newest first.</p>
      <div class="stack-actions">
        <a class="btn" href="/admin/export/starred?format=markdown">Markdown</a>
        <a class="btn" href="/admin/export/starred?format=json">JSON</a>
      </div>
    </div>
    #{admin_block}
    <div class="card">
      <h2>Subscriptions (OPML)</h2>
      <p class="muted">Feed list only.</p>
      <div class="stack-actions">
        <a class="btn" href="/admin/opml/export">Download OPML</a>
      </div>
    </div>
    """

    HTML.shell(user, flash, "Export", inner, active: "export")
  end
end
