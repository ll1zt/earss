# Shared env-file loader for mix.exs (deps) and config/runtime.exs (boot).
# Loaded via Code.require_file/1 — not part of the :earss OTP app modules.
#
# Files (project root), in order:
#   earss.env
#   earss.env.local
# Already-set process env vars are never overwritten.

defmodule Earss.EnvLoader do
  @moduledoc false

  @env_files ["earss.env", "earss.env.local"]

  # `only` restricts which keys are put into the process env. mix.exs uses it
  # to load just the plugin-dep keys at deps time — loading operator env
  # (ADMIN_PASSWORD, POLLER_*, …) into `mix test` would leak runtime config
  # into the test suite (env wins over config :earss, :operator_auth).
  def load_files(root \\ File.cwd!(), opts \\ []) do
    only = Keyword.get(opts, :only)

    Enum.each(@env_files, fn name ->
      path = Path.expand(name, root)
      if File.exists?(path), do: load_file(path, only)
    end)

    :ok
  end

  def get(name) when is_binary(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  def get(name, default) when is_binary(name) do
    get(name) || default
  end

  def get_bool(name, default) when is_binary(name) and is_boolean(default) do
    case get(name) do
      nil -> default
      v when v in ~w(true 1 yes on) -> true
      v when v in ~w(false 0 no off) -> false
      _ -> default
    end
  end

  # Returns {:ok, bool} only when the variable is set; else :unset
  def fetch_bool(name) when is_binary(name) do
    case get(name) do
      nil -> :unset
      v when v in ~w(true 1 yes on) -> {:ok, true}
      v when v in ~w(false 0 no off) -> {:ok, false}
      other -> raise "invalid boolean for #{name}: #{inspect(other)}"
    end
  end

  def get_int(name, default) when is_binary(name) and is_integer(default) do
    case get(name) do
      nil -> default
      v -> String.to_integer(v)
    end
  end

  def fetch_int(name) when is_binary(name) do
    case get(name) do
      nil -> :unset
      v -> {:ok, String.to_integer(v)}
    end
  end

  def get_str(name, default) when is_binary(name) and is_binary(default) do
    get(name) || default
  end

  def fetch_str(name) when is_binary(name) do
    case get(name) do
      nil -> :unset
      v -> {:ok, v}
    end
  end

  defp load_file(path, only) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.each(&put_line(&1, only))
  end

  defp put_line(line, only) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = value |> String.trim() |> unwrap_quotes()

        allowed? = is_nil(only) or key in only

        if key != "" and allowed? and System.get_env(key) in [nil, ""] do
          System.put_env(key, value)
        end

      _ ->
        :ok
    end
  end

  defp unwrap_quotes(value) do
    cond do
      String.length(value) >= 2 and String.starts_with?(value, "\"") and
          String.ends_with?(value, "\"") ->
        String.slice(value, 1..-2//1)

      String.length(value) >= 2 and String.starts_with?(value, "'") and
          String.ends_with?(value, "'") ->
        String.slice(value, 1..-2//1)

      true ->
        value
    end
  end
end
