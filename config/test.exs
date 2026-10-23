import Config

# Test database configuration.
# Integration tests need a real PostgreSQL database. Create it with:
#   mix test.setup       # createdb
config :phoenix_kit_manufacturing, ecto_repos: [PhoenixKitManufacturing.Test.Repo]

# `PGDATABASE` lets this suite point at a database the test role isn't
# allowed to CREATE (e.g. a shared instance) instead of the name Hex CI
# provisions for itself. Same mechanism as core phoenix_kit's
# config/test.exs — see there for the full rationale. Left unset (CI's
# case), this falls back to the previous hardcoded name. A partition suffix
# applies to either base name so parallel test runners never share a database.
pg_test_db =
  case String.trim(System.get_env("PGDATABASE", "")) do
    "" -> "phoenix_kit_manufacturing_test"
    value -> value
  end

pg_test_db = pg_test_db <> System.get_env("MIX_TEST_PARTITION", "")

# `PGPOOL` bounds the connection pool the same way core does — the default
# (`schedulers_online() * 2`) opens dozens of connections on a many-core
# box, which is fine against a private local Postgres but not against a
# shared instance already near its connection ceiling.
pg_test_pool =
  case System.get_env("PGPOOL") do
    value when is_binary(value) and value != "" ->
      case Integer.parse(String.trim(value)) do
        {size, ""} when size > 0 -> size
        _ -> raise "PGPOOL must be a positive integer, got: #{inspect(value)}"
      end

    _ ->
      System.schedulers_online() * 2
  end

config :phoenix_kit_manufacturing, PhoenixKitManufacturing.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: pg_test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: pg_test_pool

# Wire repo for PhoenixKit.RepoHelper — without this, all DB calls crash.
config :phoenix_kit, repo: PhoenixKitManufacturing.Test.Repo

# Test Endpoint for LiveView tests. `phoenix_kit_manufacturing` has no
# endpoint of its own in production — the host app provides one — so this
# endpoint only exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_manufacturing, PhoenixKitManufacturing.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "manufacturing-test-salt"],
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitManufacturing.Test.Layouts]]

config :phoenix, :json_library, Jason

config :logger, level: :warning
