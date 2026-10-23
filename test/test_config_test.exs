defmodule PhoenixKitManufacturing.TestConfigTest do
  use ExUnit.Case, async: true

  @config Path.expand("../config/test.exs", __DIR__)

  test "unset overrides retain the default database, port and pool" do
    assert config() == %{
             "database" => "phoenix_kit_manufacturing_test",
             "port" => 5432,
             "pool_size" => 4
           }
  end

  test "PGDATABASE is trimmed and blank names fall back to the test database" do
    assert config(%{"PGDATABASE" => "  shared_test  "})["database"] == "shared_test"

    for value <- ["", "   "] do
      assert config(%{"PGDATABASE" => value})["database"] == "phoenix_kit_manufacturing_test"
    end
  end

  test "MIX_TEST_PARTITION isolates both default and overridden databases" do
    assert config(%{"MIX_TEST_PARTITION" => "2"})["database"] ==
             "phoenix_kit_manufacturing_test2"

    assert config(%{"PGDATABASE" => "shared_test", "MIX_TEST_PARTITION" => "3"})["database"] ==
             "shared_test3"
  end

  test "PGPOOL accepts trimmed positive integers and defaults for an empty override" do
    assert config(%{"PGPOOL" => " 5 "})["pool_size"] == 5
    assert config(%{"PGPOOL" => ""})["pool_size"] == 4
  end

  test "invalid PGPOOL values fail before any database connection" do
    for value <- ["0", "-1", "many", "4extra", "   "] do
      assert {output, status} = read_config(%{"PGPOOL" => value})
      assert status != 0
      assert output =~ "PGPOOL must be a positive integer"
    end
  end

  test "PGPORT reaches the Ecto configuration as an integer" do
    assert config(%{"PGPORT" => "5544"})["port"] == 5544
  end

  defp config(overrides \\ %{}) do
    assert {output, 0} = read_config(overrides)
    JSON.decode!(output)
  end

  # Evaluate the real config in a separate VM with an isolated environment.
  # No test changes the running suite's repo config or process-wide env vars.
  defp read_config(overrides) do
    env =
      %{"PGDATABASE" => nil, "MIX_TEST_PARTITION" => nil, "PGPOOL" => nil, "PGPORT" => nil}
      |> Map.merge(overrides)
      |> Map.to_list()

    script = """
    config = Config.Reader.read!(#{inspect(@config)}, env: :test)
    repo = config[:phoenix_kit_manufacturing][PhoenixKitManufacturing.Test.Repo]
    repo |> Keyword.take([:database, :port, :pool_size]) |> Map.new() |> JSON.encode!() |> IO.write()
    """

    System.cmd("elixir", ["--erl", "+S 2:2", "-e", script], env: env, stderr_to_stdout: true)
  end
end
