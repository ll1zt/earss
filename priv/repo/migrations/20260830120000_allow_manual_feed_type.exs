defmodule Earss.Repo.Migrations.AllowManualFeedType do
  @moduledoc """
  Allow `feed_type = 'manual'` for agent-created container feeds
  (docs/mcp-design.md, milestone M2).

  The MCP ingest tools store content an agent collected from outside any
  feed. Entries require a parent feed (`entries.feed_id` is NOT NULL), so
  that content has to live in a container: a feed that is never fetched and
  exists only to own entries.

  `manual` is that marker. It widens the existing CHECK constraint from
  ('rss','atom','json','plugin') to include 'manual'; no other column or
  table changes.
  """
  use Ecto.Migration

  def up do
    drop constraint(:feeds, :feeds_feed_type_must_be_valid)

    create constraint(:feeds, :feeds_feed_type_must_be_valid,
      check: "feed_type IN ('rss', 'atom', 'json', 'plugin', 'manual')"
    )
  end

  def down do
    # Rows created while this migration was applied would violate the
    # narrower constraint, so move them somewhere valid before restoring it.
    # 'rss' is the least surprising landing spot for a container: it stops
    # the down migration from failing on data the operator still owns.
    execute("UPDATE feeds SET feed_type = 'rss' WHERE feed_type = 'manual'")

    drop constraint(:feeds, :feeds_feed_type_must_be_valid)

    create constraint(:feeds, :feeds_feed_type_must_be_valid,
      check: "feed_type IN ('rss', 'atom', 'json', 'plugin')"
    )
  end
end
