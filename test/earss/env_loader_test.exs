defmodule Earss.EnvLoaderTest do
  use ExUnit.Case, async: false

  # The loader lives in config/ (Code.require_file'd by mix.exs), not in the
  # compiled app modules — require it the same way mix.exs does.
  Code.require_file("config/env_loader.exs")

  test "load_files/2 with only: puts just the allowed keys" do
    dir = Path.join(System.tmp_dir!(), "earss_env_loader_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "earss.env"), """
    # operator runtime key — must NOT leak into mix tasks
    ADMIN_PASSWORD=secret-value
    FEVER_API_KEY=fever-secret
    EARSS_SOURCE_PLUGINS=github:owner/repo@main
    """)

    previous_admin = System.get_env("ADMIN_PASSWORD")
    previous_fever = System.get_env("FEVER_API_KEY")
    previous_plugins = System.get_env("EARSS_SOURCE_PLUGINS")

    on_exit(fn ->
      restore_env("ADMIN_PASSWORD", previous_admin)
      restore_env("FEVER_API_KEY", previous_fever)
      restore_env("EARSS_SOURCE_PLUGINS", previous_plugins)
      File.rm_rf!(dir)
    end)

    # Clear pre-existing values so the test is deterministic.
    System.delete_env("ADMIN_PASSWORD")
    System.delete_env("FEVER_API_KEY")
    System.delete_env("EARSS_SOURCE_PLUGINS")

    :ok = Earss.EnvLoader.load_files(dir, only: ["EARSS_SOURCE_PLUGINS"])

    assert System.get_env("EARSS_SOURCE_PLUGINS") == "github:owner/repo@main"
    refute System.get_env("ADMIN_PASSWORD")
    refute System.get_env("FEVER_API_KEY")
  end

  test "load_files/1 loads every key (runtime.exs-style behaviour)" do
    dir = Path.join(System.tmp_dir!(), "earss_env_loader_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "earss.env"), """
    ADMIN_PASSWORD=secret-value
    POLLER_INTERVAL_MS=1234
    """)

    previous_admin = System.get_env("ADMIN_PASSWORD")
    previous_poller = System.get_env("POLLER_INTERVAL_MS")

    on_exit(fn ->
      restore_env("ADMIN_PASSWORD", previous_admin)
      restore_env("POLLER_INTERVAL_MS", previous_poller)
      File.rm_rf!(dir)
    end)

    System.delete_env("ADMIN_PASSWORD")
    System.delete_env("POLLER_INTERVAL_MS")

    :ok = Earss.EnvLoader.load_files(dir)

    assert System.get_env("ADMIN_PASSWORD") == "secret-value"
    assert System.get_env("POLLER_INTERVAL_MS") == "1234"
  end

  test "already-set process env is never overwritten" do
    dir = Path.join(System.tmp_dir!(), "earss_env_loader_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "earss.env"), "ADMIN_PASSWORD=file-value\n")

    previous = System.get_env("ADMIN_PASSWORD")

    on_exit(fn ->
      restore_env("ADMIN_PASSWORD", previous)
      File.rm_rf!(dir)
    end)

    System.put_env("ADMIN_PASSWORD", "process-value")
    :ok = Earss.EnvLoader.load_files(dir)

    assert System.get_env("ADMIN_PASSWORD") == "process-value"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
