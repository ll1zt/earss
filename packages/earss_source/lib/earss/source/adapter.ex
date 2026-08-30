defmodule Earss.Source.Adapter do
  @moduledoc """
  Behaviour for feed sources: built-in native RSS/Atom/JSON and external plugins.

  ## Adapter API version

  Return `adapter_api/0` equal to `#{__MODULE__}.api_version/0` (currently **1**).
  Hosts may refuse adapters with an unsupported version.
  """

  @api_version 1

  @doc "Current contract major version implemented by this package."
  @spec api_version() :: pos_integer()
  def api_version, do: @api_version

  @type entry :: %{
          required(:link) => String.t(),
          required(:guid) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:author) => String.t() | nil,
          optional(:summary) => String.t() | nil,
          optional(:content) => String.t() | nil,
          optional(:published_at) => DateTime.t() | nil
        }

  @type feed_meta :: %{
          optional(:title) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:site_url) => String.t() | nil
        }

  @typedoc """
  Successful fetch payload. Extra keys (e.g. `:feed_type` for native) are allowed;
  hosts ignore unknown keys.
  """
  @type fetch_ok :: %{
          optional(:feed) => feed_meta(),
          required(:entries) => [entry()],
          optional(:etag) => String.t() | nil,
          optional(:last_modified) => String.t() | nil,
          optional(:content_hash) => String.t() | nil,
          optional(:cursor) => map(),
          optional(:feed_type) => String.t()
        }

  @type route_spec :: %{
          required(:path) => String.t(),
          required(:description) => String.t(),
          optional(:params) => [map()],
          optional(:example) => String.t()
        }

  @type resolve_ok :: %{
          required(:source_url) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:meta) => map(),
          optional(:min_refresh_interval) => pos_integer(),
          optional(:max_refresh_interval) => pos_integer(),
          optional(:default_refresh_interval) => pos_integer()
        }

  @doc "Stable adapter id (e.g. `\"native\"`, `\"bilibili\"`)."
  @callback id() :: String.t()

  @doc "Contract version this module implements (use `Earss.Source.Adapter.api_version/0`)."
  @callback adapter_api() :: pos_integer()

  @doc "Human-oriented route catalog for UIs and docs."
  @callback routes() :: [route_spec()]

  @doc """
  Normalize subscription input to a canonical `source_url` and defaults.

  For `earss://` inputs, adapters validate the route. Native accepts `http(s)`.
  """
  @callback resolve(input :: String.t() | map()) ::
              {:ok, resolve_ok()} | {:error, term()}

  @doc """
  One poll cycle. Must not write to the database.

  `feed` is a host feed struct/map with at least `:link` and optional cache
  fields (`:etag`, `:last_modified`, `:last_fetched_content_hash`, `:adapter_cursor`).

  Options commonly include:

    * `:force` — skip conditional short-circuits when true
  """
  @callback fetch(feed :: struct() | map(), opts :: keyword()) ::
              {:ok, fetch_ok()}
              | {:ok, :not_modified}
              | {:error, term()}

  @doc """
  Optionally fetch content older than the feed window (backfill).

  Feeds only expose their most recent items, so "history outside the RSS
  window" has to come from a site-specific mechanism: an archive page, a
  paginated API, or a cursor the adapter already maintains. Only the plugin
  knows how to do that, which is why this is an **optional** callback: an
  adapter that does not implement it simply has no backfill capability, and
  callers probe with `function_exported?/3` rather than calling blindly.

  Returning the same shape as `fetch/2` lets the host run backfill results
  through the identical ingest path, so ordering, sanitisation and hash
  de-duplication behave exactly as they do for a normal crawl.
  """
  @callback backfill(feed :: struct() | map(), opts :: keyword()) ::
              {:ok, fetch_ok()} | {:error, term()}

  @optional_callbacks backfill: 2
end
