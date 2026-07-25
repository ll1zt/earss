defmodule Earss.Admin.Views.Categories do
  @moduledoc false

  alias Earss.Admin.HTML

  def index(user, flash, cats, counts) do
    rows =
      Enum.map(cats, fn c ->
        n = Map.get(counts, c.id, 0)

        """
        <tr>
          <td>
            <form method="post" action="/admin/categories/#{c.id}" class="stack-actions">#{HTML.csrf_input()}
              <input name="name" value="#{HTML.h(c.name)}" required style="max-width:220px"/>
              <input name="position" type="number" min="0" value="#{c.position}" style="max-width:90px"/>
              <button type="submit" class="secondary">Save</button>
            </form>
          </td>
          <td>#{n}</td>
          <td class="actions">
            <a class="btn secondary" href="/admin/subscriptions?category_id=#{c.id}">View</a>
            <form method="post" action="/admin/categories/#{c.id}/delete" onsubmit="return confirm('Delete category? Subscriptions keep their feeds.')">#{HTML.csrf_input()}
              <button type="submit" class="danger">Delete</button>
            </form>
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    empty =
      if rows == "" do
        ~s(<tr><td colspan="3" class="empty">No categories yet.</td></tr>)
      else
        rows
      end

    inner = """
    <div class="card">
      <h2>Create</h2>
      <form method="post" action="/admin/categories" class="filters">#{HTML.csrf_input()}
        <div class="field">
          <label>Name</label>
          <input name="name" required/>
        </div>
        <div class="field">
          <label>Position</label>
          <input name="position" type="number" min="0" value="0"/>
        </div>
        <div class="field">
          <button type="submit">Create</button>
        </div>
      </form>
    </div>
    <div class="card">
      <table>
        <thead><tr><th>Name / position</th><th>Subs</th><th></th></tr></thead>
        <tbody>#{empty}</tbody>
      </table>
    </div>
    """

    HTML.shell(user, flash, "Categories", inner, active: "categories")
  end
end
