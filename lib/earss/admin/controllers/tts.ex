defmodule Earss.Admin.Controllers.TTS do
  @moduledoc false

  import Earss.Admin.Helpers
  import Earss.Admin.ControllerHelpers

  alias Earss.Admin.Batch
  alias Earss.Admin.Views.TTS, as: View
  alias Earss.Repo
  alias Earss.TTS

  def index(conn) do
    configured_gate(conn, fn conn ->
      state = normalize_state(conn.params["state"])

      html(
        conn,
        View.index(user(conn), flash(conn), %{
          stats: TTS.stats(),
          providers: Earss.TTS.Registry.list_providers(),
          requests: TTS.list_requests_recent(state: state, preload_entry: true),
          state: state,
          tts_cfg: Application.get_env(:earss, :tts, [])
        })
      )
    end)
  end

  # Batch requeue/delete over selected rows (Earss.Admin.Batch plumbing).
  def batch(conn) do
    configured_gate(conn, fn conn ->
      ids = Batch.ids(conn)
      action = bp(conn, "action")

      if ids == [] do
        conn
        |> put_flash(:err, "No requests selected")
        |> redirect("/admin/tts")
      else
        requests = from_rows(ids)

        {ok_n, fail_n, notes} =
          Batch.run(requests, fn r -> "##{r.id}" end, fn r ->
            do_batch_action(r, action)
          end)

        conn
        |> put_flash(
          Batch.flash_type(ok_n, fail_n),
          Batch.message(action || "?", ok_n, fail_n, notes)
        )
        |> redirect("/admin/tts")
      end
    end)
  end

  def requeue(conn) do
    configured_gate(conn, fn conn ->
      id = parse_id!(conn)

      case TTS.requeue(id) do
        {:ok, _} ->
          conn
          |> put_flash(:ok, "Request ##{id} requeued — the worker picks it up on its next tick")
          |> redirect("/admin/tts")

        {:error, reason} ->
          conn
          |> put_flash(:err, "Could not requeue ##{id}: #{format_error(reason)}")
          |> redirect("/admin/tts")
      end
    end)
  end

  def delete(conn) do
    configured_gate(conn, fn conn ->
      id = parse_id!(conn)

      case TTS.delete_request(id) do
        {:ok, %{row: true, file: true}} ->
          flash_msg(:ok, id, "deleted (row and audio removed)", conn)

        {:ok, %{row: true, file: false}} ->
          flash_msg(:ok, id, "deleted (no audio file to remove)", conn)

        {:error, reason} ->
          conn
          |> put_flash(:err, "Could not delete ##{id}: #{format_error(reason)}")
          |> redirect("/admin/tts")
      end
    end)
  end

  # —— internals ——

  # The page only exists when TTS is configured (the nav hides the entry
  # too); a direct hit gets the same "Not found" flash the catch-all route
  # produces, so unauthenticated-looking paths behave consistently.
  defp configured_gate(conn, fun) do
    if TTS.configured?() do
      with_user(conn, fun)
    else
      conn
      |> put_flash(:err, "Not found")
      |> redirect("/admin")
    end
  end

  defp user(conn), do: conn.assigns.admin_user

  defp normalize_state(state) when state in ["requested", "processing", "ready", "failed"],
    do: String.to_existing_atom(state)

  defp normalize_state(_), do: nil

  defp from_rows(ids) do
    import Ecto.Query, warn: false

    Earss.TTS.Request
    |> where([r], r.id in ^ids)
    |> Repo.all()
  end

  defp do_batch_action(request, "requeue"), do: TTS.requeue(request.id)
  defp do_batch_action(request, "delete"), do: TTS.delete_request(request.id)

  defp do_batch_action(_request, action) when is_binary(action),
    do: {:error, {:unknown_action, action}}

  defp do_batch_action(_request, _action), do: {:error, :missing_action}

  # Router matches integers, but parse defensively anyway.
  defp parse_id!(conn) do
    case Integer.parse(conn.path_params["id"]) do
      {id, ""} -> id
      _ -> 0
    end
  end

  defp flash_msg(type, id, text, conn) do
    conn
    |> put_flash(type, "Request ##{id} #{text}")
    |> redirect("/admin/tts")
  end
end
