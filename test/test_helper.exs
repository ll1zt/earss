ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Earss.Repo, :manual)
Earss.Feeds.HTTPStub.ensure_table!()

# Bypass serves local HTTP fixtures for transport-level tests (redirects,
# body caps); its Application must be running for Bypass.open/1.
{:ok, _} = Application.ensure_all_started(:bypass)
