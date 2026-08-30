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
  defstruct [:name, :description, :input_schema, :mutating, :handler]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          mutating: boolean(),
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
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)

    %__MODULE__{
      name: name,
      description: Keyword.fetch!(opts, :description),
      input_schema: Keyword.get(opts, :input_schema, empty_schema()),
      mutating: Keyword.get(opts, :mutating, true),
      handler: Keyword.fetch!(opts, :handler)
    }
  end

  @doc """
  The wire form: everything the client needs, nothing that cannot be encoded.
  """
  @spec definition(t()) :: map()
  def definition(%__MODULE__{} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      inputSchema: tool.input_schema
    }
  end

  @doc """
  JSON Schema for a tool that takes no parameters.

  The spec allows `{type: :object}` here, but `additionalProperties: false`
  is the recommended form: it accepts only empty objects and rejects callers
  that send unexpected keys.
  """
  @spec empty_schema() :: map()
  def empty_schema, do: %{type: "object", properties: %{}, additionalProperties: false}
end
