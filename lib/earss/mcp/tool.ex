defmodule Earss.MCP.Tool do
  @moduledoc """
  One MCP tool: the advertised definition plus its handler, kept apart.

  The split exists because the definition is serialized to the client on
  `tools/list` while the handler is a local function. Keeping them in one map
  meant the function ended up in the advertised schema, which `Jason` refuses
  to encode.

  `definition/1` is what goes on the wire; `handler/1` stays server-side.
  """

  @enforce_keys [:name, :description, :input_schema, :mutating, :handler]
  defstruct [:name, :description, :input_schema, :mutating, :destructive, :impact, :handler]

  @type impact_fn :: (map() -> map())

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          mutating: boolean(),
          destructive: boolean(),
          impact: impact_fn() | nil,
          handler: (map() -> {:ok, term()} | {:error, term()})
        }

  @doc """
  Build a tool.

  `opts` requires `:description` and `:handler`, and accepts:

    * `:name` — unique, snake_case, domain-prefixed (defaults to the caller's
      own name, so prefer passing it explicitly)
    * `:input_schema` — JSON Schema; defaults to an empty object, which is
      the spec's recommended form for a tool with no parameters
    * `:mutating` — true for anything that changes state; such tools are
      hidden and rejected in read-only mode (default `true`, so a forgotten
      flag fails closed)
    * `:destructive` — true when the change is hard to undo (unsubscribing
      drops read state, deleting a category unfiles its subscriptions).
      Destructive tools run in two phases: called without `confirm: true`
      they return an impact report instead of acting, so the caller can
      show the operator what is about to happen (default `false`)
    * `:impact` — `(args -> map)` describing what the call would affect;
      used to build the report in the confirmation phase. Strongly
      recommended for every destructive tool
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)

    %__MODULE__{
      name: name,
      description: Keyword.fetch!(opts, :description),
      input_schema: Keyword.get(opts, :input_schema, empty_schema()),
      mutating: Keyword.get(opts, :mutating, true),
      destructive: Keyword.get(opts, :destructive, false),
      impact: Keyword.get(opts, :impact),
      handler: Keyword.fetch!(opts, :handler)
    }
  end

  @doc """
  The wire form: everything the client needs, nothing that cannot be encoded.

  Destructive tools carry standard MCP annotations so conforming clients can
  surface them (the spec says clients SHOULD confirm destructive calls).
  """
  @spec definition(t()) :: map()
  def definition(%__MODULE__{} = tool) do
    base = %{
      name: tool.name,
      description: tool.description,
      inputSchema: tool.input_schema
    }

    if tool.destructive do
      Map.put(base, :annotations, %{destructiveHint: true, readOnlyHint: false})
    else
      base
    end
  end

  @doc """
  JSON Schema for a tool that takes no parameters.

  The spec allows `{type: :object}` here, but `additionalProperties: false`
  is the recommended form: it accepts only empty objects and rejects callers
  that send unexpected keys.
  """
  @spec empty_schema() :: map()
  def empty_schema, do: %{type: "object", properties: %{}, additionalProperties: false}

  @doc """
  Render a changeset's validation errors as one line for an agent.

  Ecto returns errors as `{field, {message, opts}}`; a raw `inspect/1` of
  that is close to unreadable, and the interpolated values (`%{count}`,
  `%{max}`) stay unreplaced. Flattening to `"field message, message; …"`
  gives the model something it can act on — usually by retrying with a
  corrected argument.

  Shared by every tool that writes through a changeset, so all of them
  report errors in the same shape.
  """
  @spec format_changeset(Ecto.Changeset.t()) :: String.t()
  def format_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end
end
