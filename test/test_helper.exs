# Test helper for the PhoenixKitManufacturing test suite.
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests require PostgreSQL — automatically excluded
#          when the database is unavailable (`:integration` tag).
#
# To enable integration tests:
#
#     mix test.setup           # createdb
#     mix test
#
# The test endpoint runs with `server: false` (no port opened); LiveView
# tests drive it via `Phoenix.LiveViewTest.live/2` only.

# Elixir 1.19's `mix test` no longer auto-loads modules from the
# `:elixirc_paths` test directories at test-helper time — only files
# matching `:test_load_filters` get loaded by the test runner. Our support
# modules are compiled but not loaded, so explicit `Code.require_file/2`
# calls are needed before this file references them.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "machines_migration.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

# Check if the test database exists.
db_name =
  Application.get_env(:phoenix_kit_manufacturing, PhoenixKitManufacturing.Test.Repo)[:database] ||
    "phoenix_kit_manufacturing_test"

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    # `psql` not installed in PATH — fall through to the connect path, which
    # will fail gracefully and exclude :integration tests.
    ErlangError -> :try_connect
  end

# Stop the repo supervisor so a pool that can't reach the DB doesn't keep
# spewing background reconnect errors for the rest of the run — and so
# `Routes.path/1` (used by the `Paths` unit tests) fails fast on a missing
# repo instead of blocking ~4s on a dead connection queue.
stop_repo = fn
  {:ok, pid} when is_pid(pid) -> Supervisor.stop(pid)
  _ -> :ok
end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Test database "#{db_name}" not found — integration tests will be excluded.
       Run `mix test.setup` to create the test database.
    """)

    false
  else
    started =
      case PhoenixKitManufacturing.Test.Repo.start_link() do
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end

    try do
      {:ok, _pid} = started

      # Build the core schema by running core's versioned migrations, then
      # apply this module's own tables via its migration_module. Both go
      # through `Ecto.Migrator.up/4` — a fresh microsecond version each time,
      # so re-runs no-op (the DDL is `IF NOT EXISTS`) without colliding. The
      # module migration runs via a static wrapper module so
      # `Ecto.Migration.execute/1` finds its runner process. Schema drift
      # impossible by construction — no hand-rolled migration shim.
      PhoenixKit.Migration.ensure_current(PhoenixKitManufacturing.Test.Repo, log: false)

      Ecto.Migrator.up(
        PhoenixKitManufacturing.Test.Repo,
        System.os_time(:microsecond),
        PhoenixKitManufacturing.Test.MachinesMigration,
        log: false
      )

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitManufacturing.Test.Repo, :manual)
      true
    rescue
      e ->
        stop_repo.(started)

        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        stop_repo.(started)

        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_manufacturing, :test_repo_available, repo_available)

# Start minimal PhoenixKit services so the module's runtime dependencies
# (PubSub topics, ModuleRegistry) resolve during tests.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# Exclude integration tests when the DB is not available.
exclude = if repo_available, do: [], else: [:integration]

# Force PhoenixKit's URL prefix cache to an empty string for tests so
# `Paths.*` produce paths the test router can match. Admin paths always get
# the default locale ("en") prefix, so our router scope is
# `/en/admin/manufacturing`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint so Phoenix.LiveViewTest can drive our LiveViews
# via `live/2` with real URLs. Runs with `server: false`, so no port is
# opened. Only starts when the test DB is available.
if repo_available do
  {:ok, _} = PhoenixKitManufacturing.Test.Endpoint.start_link()
end

ExUnit.start(exclude: exclude)
