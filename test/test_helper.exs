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
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

# Start minimal PhoenixKit services *before* touching the database.
# `EntitiesRegistry.init/1` (started, and immediately stopped again, once
# below to seed its blueprint entities ahead of any per-test sandbox
# transaction) calls `PhoenixKitEntities.Entities.create_entity/2` /
# `EntityData.create/2`, both of which unconditionally broadcast a PubSub
# event on success (`PhoenixKitEntities.Events`, routed through
# `PhoenixKit.PubSub.Manager`). `Phoenix.PubSub.broadcast/3` raises
# `ArgumentError` ("unknown registry: :phoenix_kit_internal_pubsub") when
# that named PubSub isn't started yet — which, before this reorder, was
# the case here (`PubSub.Manager` used to start *after* the provisioning
# step ran below), so every real-database `mix test` run hit that raise
# inside the `try` block below, got caught by its `rescue`, and silently
# mis-reported "could not connect to test database" — excluding every
# `:integration` test even with Postgres up and reachable. `ModuleRegistry`
# has no such ordering constraint but is started alongside it for the same
# reason the two were already grouped together.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

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

      # Build the schema by running core's versioned migrations — as of
      # core V143 this module ships no migrations of its own (see
      # CLAUDE.md's "Database & migrations" section); `phoenix_kit_machines`
      # and the rest of this module's runtime tables are created by the
      # same call, core-owned. `ensure_current/2`'s DDL is `IF NOT
      # EXISTS`-idempotent, so a re-run against an already-migrated
      # database (a `mix test` rerun against a not-`test.reset`'d database)
      # no-ops cleanly.
      PhoenixKit.Migration.ensure_current(PhoenixKitManufacturing.Test.Repo, log: false)

      # `EntitiesRegistry.init/1`'s blueprint-entity provisioning
      # (`provision_blueprints/0`) needs a real `created_by_uuid` — a
      # freshly `createdb`'d test database has zero PhoenixKit users at
      # this point, so seed exactly one before starting the registry
      # below. Provisioning itself degrades gracefully with no users
      # present (logs and defers to the next reload — see the registry's
      # moduledoc), but several tests (e.g. `MachineTypeTemplateLiveTest`)
      # look the blueprint entities up directly without ever starting
      # `EntitiesRegistry` themselves, so we still want them to exist
      # deterministically before any test runs. Guarded on
      # `get_first_user_uuid/0` so this stays a no-op on the second and
      # later `mix test` run against the same (not `test.reset`'d)
      # database. Inserted directly (not via `Auth.register_user/2`) — no
      # rate limiter or mailer is running yet this early in boot, and none
      # of that ceremony matters for a row whose only purpose is to exist
      # as a creator reference.
      if is_nil(PhoenixKit.Users.Auth.get_first_user_uuid()) do
        %PhoenixKit.Users.Auth.User{}
        |> Ecto.Changeset.cast(
          %{
            email: "test-helper-fixture@phoenix-kit-manufacturing.test",
            hashed_password: "not-a-real-hash"
          },
          [:email, :hashed_password]
        )
        |> PhoenixKitManufacturing.Test.Repo.insert!()
      end

      # Start-and-immediately-stop `EntitiesRegistry` once here, before the
      # sandbox mode switch below: its `init/1` runs the same idempotent
      # `provision_blueprints/0` a real host boot does, permanently
      # committing the "machine_type" / "operation" / "defect_reason"
      # blueprint entities (see the registry's moduledoc) while the
      # connection is still unsandboxed — mirrors how the module's own
      # now-removed migration used to seed them once, up front, for the
      # whole suite (see `dev_docs/LEGACY_DATA_MIGRATION.md`). Stopped
      # right away so its globally-registered process name
      # (`GenServer.start_link(..., name: __MODULE__)`) is free for
      # individual tests' own `start_supervised!(EntitiesRegistry)` calls —
      # those find the blueprints already provisioned and no-op through
      # `ensure_blueprint_entity/2`'s existing-entity branch.
      {:ok, registry_pid} = PhoenixKitManufacturing.EntitiesRegistry.start_link([])
      GenServer.stop(registry_pid)

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
