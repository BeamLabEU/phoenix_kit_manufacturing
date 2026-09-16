defmodule PhoenixKitManufacturing.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitManufacturing.Migrations

  @moduledoc """
  Pins the ownership design for `phoenix_kit_manufacturing`: this package
  owns all 3 `phoenix_kit_machine*` tables' FUTURE shape through its module
  migration chain, while core's V144 baseline still creates every table on
  every install, and the chain's V1 merely ADOPTS that shape (stamps the
  `pkm_schema:` marker on the anchor table, `phoenix_kit_machines`, changes
  no shape at all — see `PhoenixKitManufacturing.Migrations`' moduledoc).

  Every test here is a pure data/string assertion over
  `up_statements/2`/`down_statements/2`/`up/1`/`down/1`-as-source-text and
  core's static `PhoenixKit.Migrations.ExpectedSchema.objects/1` manifest —
  none of them touch a database.
  """

  @machine_tables ~w(
    phoenix_kit_machines
    phoenix_kit_machine_type_assignments
    phoenix_kit_machine_operations
  )

  test "PhoenixKitManufacturing declares the module-owned migration chain" do
    # Assert the VALUE, not `function_exported?/3` — `use PhoenixKit.Module`
    # injects an overridable default `migration_module/0`, so exportedness
    # says nothing about whether this module declares one.
    assert Code.ensure_loaded?(PhoenixKitManufacturing)

    assert PhoenixKitManufacturing.migration_module() == Migrations,
           """
           PhoenixKitManufacturing no longer declares its migration chain \
           (migration_module/0 returned #{inspect(PhoenixKitManufacturing.migration_module())}).

           The chain is how phoenix_kit_manufacturing's future shape is versioned
           (pkm_schema marker) and how `mix phoenix_kit.update` migrates hosts.
           """
  end

  describe "the coordinator implements the protocol" do
    alias PhoenixKit.Migrations.Postgres.Helpers

    test "current_version/0 and version_table/0" do
      assert Migrations.current_version() == 1
      assert Migrations.version_table() == "phoenix_kit_machines"
    end

    test "initial_version/0" do
      assert Migrations.initial_version() == 1
    end

    # `mix phoenix_kit_hello_world.audit_migrations` (the canonical auditor
    # for this protocol) refuses to drive a coordinator missing any of these
    # five — `mix phoenix_kit.update` itself only calls
    # `migrated_version_runtime/1` + `current_version/0`, but `up/1` needs
    # `migrated_version/1` to re-read the version it is about to change.
    test "exports the full five-function protocol, plus version_table/0 and initial_version/0" do
      for {fun, arity} <- [
            {:current_version, 0},
            {:up, 1},
            {:down, 1},
            {:migrated_version, 1},
            {:migrated_version_runtime, 1},
            {:version_table, 0},
            {:initial_version, 0}
          ] do
        assert function_exported?(Migrations, fun, arity),
               "#{inspect(Migrations)} does not export #{fun}/#{arity}"
      end
    end

    # The marker decides whether any LATER version ever runs: core's
    # `classify/2` reads it and answers `:up_to_date` for every version at or
    # below it. Stamping a version this chain does not have therefore skips
    # V2 and everything after it, silently and permanently.
    test "refuses to stamp a version this chain does not have" do
      too_high = Migrations.current_version() + 1

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.up_statements("public", too_high)
      end

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.down_statements("public", too_high)
      end

      # The ceiling itself stays reachable, or the guard would just break
      # the chain instead of bounding it.
      assert Migrations.up_statements("public", Migrations.current_version()) != []
    end

    # This chain interpolates the prefix into every object it creates, and
    # Postgres TRUNCATES an identifier past 63 bytes silently rather than
    # rejecting it — so a prefix core would refuse yields object names that
    # differ from core's while every command still exits 0, breaking the
    # contract adoption rests on. The rules are therefore core's, and this
    # test compares against core rather than restating them.
    test "every public builder that emits SQL validates its own prefix" do
      for fun <- [:up_statements, :down_statements] do
        assert_raise ArgumentError, fn -> apply(Migrations, fun, ["EVIL\";DROP"]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [String.duplicate("a", 30)]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [123]) end
      end
    end

    test "the prefix rules are core's, case and length included" do
      for prefix <- [
            "public",
            "machines_alt",
            "Machines",
            "9leading_digit",
            "has-dash",
            String.duplicate("a", 20),
            String.duplicate("a", 21),
            String.duplicate("a", 30)
          ] do
        core_accepts =
          try do
            Helpers.validate_prefix!(prefix)
            true
          rescue
            ArgumentError -> false
          end

        ours_accepts =
          try do
            Migrations.up_statements(prefix)
            true
          rescue
            ArgumentError -> false
          end

        assert ours_accepts == core_accepts,
               "prefix #{inspect(prefix)}: core #{if core_accepts, do: "accepts", else: "rejects"}, " <>
                 "this chain #{if ours_accepts, do: "accepts", else: "rejects"} — the two must agree, " <>
                 "or the object names this chain creates stop matching core's"
      end
    end

    test "rejects a prefix that cannot be safely interpolated into DDL" do
      for bad <- ["public.\"; DROP TABLE x; --", "1st", "a-b", ""] do
        assert_raise ArgumentError, fn -> Migrations.up_statements(bad) end
        assert_raise ArgumentError, fn -> Migrations.down_statements(bad, 0) end
      end
    end
  end

  describe "the chain's per-version statement content is pinned (drift guard)" do
    # V1 is a PUBLISHED version once this ships. A host that has already run
    # it will never run it again, so editing its content does not "fix" that
    # host — it silently splits fresh installs from existing ones. Pinning
    # the exact normalised text makes that split a deliberate, visible diff
    # instead of an accidental one buried in a refactor.
    defp normalised(statements),
      do: Enum.map(statements, &(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))

    test "V1's published statements are frozen" do
      v1 = Migrations.up_statements("public", 1) |> normalised()

      assert v1 == [
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_machines ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"name\" character varying(255) NOT NULL, \"code\" character varying(100), \"manufacturer\" character varying(255), \"serial_number\" character varying(255), \"description\" text, \"location_note\" character varying(500), \"status\" character varying(20) DEFAULT 'active'::character varying NOT NULL, \"data\" jsonb DEFAULT '{}'::jsonb NOT NULL, \"metadata\" jsonb DEFAULT '{}'::jsonb NOT NULL, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL, \"model\" character varying(255), \"manufacture_year\" integer, \"commissioned_on\" date, \"warranty_until\" date, \"to_last_on\" date, \"to_interval_days\" integer, \"to_next_on\" date, \"notes\" text, \"location_uuid\" uuid, \"space_uuid\" uuid )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_machine_type_assignments ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"machine_uuid\" uuid NOT NULL, \"machine_type_uuid\" uuid NOT NULL, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_machine_operations ( \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL, \"machine_uuid\" uuid NOT NULL, \"operation_uuid\" uuid NOT NULL, \"time_norm_seconds\" integer, \"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL, \"updated_at\" timestamp with time zone DEFAULT now() NOT NULL )",
               "ALTER TABLE public.phoenix_kit_machines ADD COLUMN IF NOT EXISTS \"model\" character varying(255)",
               "ALTER TABLE public.phoenix_kit_machines ADD COLUMN IF NOT EXISTS \"manufacture_year\" integer",
               "ALTER TABLE public.phoenix_kit_machines ADD COLUMN IF NOT EXISTS \"commissioned_on\" date",
               "ALTER TABLE public.phoenix_kit_machines ADD COLUMN IF NOT EXISTS \"warranty_until\" date",
               "ALTER TABLE public.phoenix_kit_machines ADD COLUMN IF NOT EXISTS \"to_last_on\" date",
               "ALTER TABLE public.phoenix_kit_machines ADD COLUMN IF NOT EXISTS \"to_interval_days\" integer",
               "ALTER TABLE public.phoenix_kit_machines ADD COLUMN IF NOT EXISTS \"to_next_on\" date",
               "ALTER TABLE public.phoenix_kit_machines ADD COLUMN IF NOT EXISTS \"notes\" text",
               "ALTER TABLE public.phoenix_kit_machines ADD COLUMN IF NOT EXISTS \"location_uuid\" uuid",
               "ALTER TABLE public.phoenix_kit_machines ADD COLUMN IF NOT EXISTS \"space_uuid\" uuid",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_machines_pkey' AND t.relname = 'phoenix_kit_machines' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_machines ADD CONSTRAINT phoenix_kit_machines_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_machine_type_assignments_pkey' AND t.relname = 'phoenix_kit_machine_type_assignments' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_machine_type_assignments ADD CONSTRAINT phoenix_kit_machine_type_assignments_pkey PRIMARY KEY (uuid); END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_machine_operations_pkey' AND t.relname = 'phoenix_kit_machine_operations' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_machine_operations ADD CONSTRAINT phoenix_kit_machine_operations_pkey PRIMARY KEY (uuid); END IF; END $$",
               "CREATE INDEX IF NOT EXISTS idx_machines_status ON public.phoenix_kit_machines USING btree (status)",
               "CREATE INDEX IF NOT EXISTS idx_machines_location ON public.phoenix_kit_machines USING btree (location_uuid)",
               "CREATE UNIQUE INDEX IF NOT EXISTS idx_machine_type_assignments_unique ON public.phoenix_kit_machine_type_assignments USING btree (machine_uuid, machine_type_uuid)",
               "CREATE INDEX IF NOT EXISTS idx_machine_type_assignments_type ON public.phoenix_kit_machine_type_assignments USING btree (machine_type_uuid)",
               "CREATE UNIQUE INDEX IF NOT EXISTS idx_machine_operations_unique ON public.phoenix_kit_machine_operations USING btree (machine_uuid, operation_uuid)",
               "CREATE INDEX IF NOT EXISTS idx_machine_operations_operation ON public.phoenix_kit_machine_operations USING btree (operation_uuid)",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_machine_type_assignments_machine_uuid_fkey' AND t.relname = 'phoenix_kit_machine_type_assignments' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_machine_type_assignments ADD CONSTRAINT phoenix_kit_machine_type_assignments_machine_uuid_fkey FOREIGN KEY (machine_uuid) REFERENCES public.phoenix_kit_machines(uuid) ON DELETE CASCADE; END IF; END $$",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_machine_operations_machine_uuid_fkey' AND t.relname = 'phoenix_kit_machine_operations' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_machine_operations ADD CONSTRAINT phoenix_kit_machine_operations_machine_uuid_fkey FOREIGN KEY (machine_uuid) REFERENCES public.phoenix_kit_machines(uuid) ON DELETE CASCADE; END IF; END $$",
               "COMMENT ON TABLE public.phoenix_kit_machines IS 'pkm_schema:1'"
             ]
    end
  end

  describe "the chain DDL adopts core's V144 shape" do
    test "V1 uses core's exact object names (shape-identical adoption)" do
      statements = Enum.join(Migrations.up_statements(), "\n")

      for name <- [
            "phoenix_kit_machines_pkey",
            "phoenix_kit_machine_type_assignments_pkey",
            "phoenix_kit_machine_operations_pkey",
            "idx_machines_status",
            "idx_machines_location",
            "idx_machine_type_assignments_unique",
            "idx_machine_type_assignments_type",
            "idx_machine_operations_unique",
            "idx_machine_operations_operation",
            "phoenix_kit_machine_type_assignments_machine_uuid_fkey",
            "phoenix_kit_machine_operations_machine_uuid_fkey"
          ] do
        assert statements =~ name,
               "V1 no longer creates #{name} — it must stay shape-identical to core's V144"
      end
    end

    test "up stamps the version marker, and stamps it last" do
      statements = Migrations.up_statements()

      assert List.last(statements) ==
               "COMMENT ON TABLE public.phoenix_kit_machines IS 'pkm_schema:1'",
             "the marker must be stamped after the DDL it certifies, not before"
    end

    test "applying up to version 0 is not an operation" do
      assert Migrations.up_statements("public", 0) == []
      assert Migrations.up_statements("machines_alt", 0) == []
    end

    test "every up statement is guarded (IF NOT EXISTS / DO-block idempotence)" do
      # V1 runs on installs where core's V144 already created everything, so
      # every statement must be a no-op against an object that is already
      # there. One exemption: the marker COMMENT — not a guarded operation,
      # it's the thing being stamped.
      exempt = ["COMMENT ON TABLE public.phoenix_kit_machines IS 'pkm_schema:1'"]

      ddl = Enum.reject(Migrations.up_statements(), &(&1 in exempt))

      for stmt <- ddl do
        assert stmt =~ "IF NOT EXISTS",
               "statement is not idempotent against a core-created table:\n#{stmt}"
      end
    end

    # Section order matters: a table must exist before its safety-net ALTER,
    # pkey, index or FK guard runs; the marker must certify a finished
    # shape. Unlike customer_support's chain, there is no "checks" section —
    # none of these 3 tables has a CHECK constraint.
    test "statement sections appear in the order tables -> alter-safety-net -> pkeys -> indexes -> fks -> marker" do
      statements = Migrations.up_statements()

      sections =
        Enum.map(statements, fn stmt ->
          cond do
            String.starts_with?(stmt, "CREATE TABLE") -> :table
            String.starts_with?(stmt, "ALTER TABLE") -> :alter
            String.starts_with?(stmt, "COMMENT ON TABLE") -> :marker
            String.starts_with?(stmt, "CREATE") -> :index
            String.starts_with?(stmt, "DO") -> :constraint
          end
        end)

      # Every :constraint DO block is a pkey or an fk — the 3 pkeys are
      # guaranteed to precede indexes (they run back to back, with no index
      # between them, so they dedup into one :constraint run) and the 2 fks
      # are guaranteed to follow indexes, by construction (see
      # up_statements/2 below). `Enum.dedup/1`, not `Enum.uniq/1`: uniq
      # would collapse the pkey :constraint run and the later fk
      # :constraint run into one, silently hiding indexes sorted in between
      # the two.
      order = Enum.dedup(sections)

      assert order == [:table, :alter, :constraint, :index, :constraint, :marker],
             "sections are out of order: #{inspect(order)}"
    end
  end

  describe "the chain never creates an FK on either soft reference" do
    # The one addition beyond customer_support's file: this module has TWO
    # soft-reference columns (no FK by design — see the moduledoc's "No FK
    # on the soft references" section), and a naive reading of core's
    # `CREATE TABLE` text could tempt a future edit into "fixing" that by
    # adding one back. Pin the negative directly, for every prefix/target.
    test "up_statements/2 never emits a FOREIGN KEY on machine_type_uuid or operation_uuid" do
      for prefix <- ["public", "machines_alt"] do
        for target <- [0, 1] do
          statements = Enum.join(Migrations.up_statements(prefix, target), "\n")

          refute statements =~ "FOREIGN KEY (machine_type_uuid)",
                 "up_statements(#{inspect(prefix)}, #{target}) adds an FK on the soft " <>
                   "reference machine_type_uuid — see the moduledoc before adding one"

          refute statements =~ "FOREIGN KEY (operation_uuid)",
                 "up_statements(#{inspect(prefix)}, #{target}) adds an FK on the soft " <>
                   "reference operation_uuid — see the moduledoc before adding one"
        end
      end
    end
  end

  describe "the chain can never destroy any of the 3 tables" do
    alias PhoenixKit.Migrations.ExpectedSchema

    # Compared against the WHOLE expected content, not scanned for a
    # forbidden substring — a substring check only sees statements the
    # builder produced, so anything appended past it (a literal
    # `execute("DROP TABLE ...")` in `up/1`) would be invisible to it. That
    # path is closed by the source-text test below, which checks what is
    # executed rather than what is built.
    test "down/1 emits exactly the marker bookkeeping, in every target and prefix" do
      assert Migrations.down_statements("public", 0) ==
               ["COMMENT ON TABLE public.phoenix_kit_machines IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               ["COMMENT ON TABLE public.phoenix_kit_machines IS 'pkm_schema:1'"]

      assert Migrations.down_statements("machines_alt", 0) ==
               ["COMMENT ON TABLE machines_alt.phoenix_kit_machines IS NULL"]

      assert Migrations.down_statements("machines_alt", 1) ==
               ["COMMENT ON TABLE machines_alt.phoenix_kit_machines IS 'pkm_schema:1'"]
    end

    # For `up/1` the expected content is the full set of OPERATIONS rather
    # than the full SQL text. An operation is `{verb, object}`, immune to
    # reformatting and still failing on any statement added, removed or
    # retargeted — including a destructive one, which cannot enter this set
    # without changing it.
    @up_operations [
      {"CREATE TABLE", "phoenix_kit_machines"},
      {"CREATE TABLE", "phoenix_kit_machine_type_assignments"},
      {"CREATE TABLE", "phoenix_kit_machine_operations"},
      {"ALTER TABLE", "phoenix_kit_machines"},
      {"DO", "phoenix_kit_machines_pkey"},
      {"DO", "phoenix_kit_machine_type_assignments_pkey"},
      {"DO", "phoenix_kit_machine_operations_pkey"},
      {"CREATE INDEX", "idx_machines_status"},
      {"CREATE INDEX", "idx_machines_location"},
      {"CREATE UNIQUE INDEX", "idx_machine_type_assignments_unique"},
      {"CREATE INDEX", "idx_machine_type_assignments_type"},
      {"CREATE UNIQUE INDEX", "idx_machine_operations_unique"},
      {"CREATE INDEX", "idx_machine_operations_operation"},
      {"DO", "phoenix_kit_machine_type_assignments_machine_uuid_fkey"},
      {"DO", "phoenix_kit_machine_operations_machine_uuid_fkey"},
      {"COMMENT ON TABLE", "phoenix_kit_machines"}
    ]

    test "up_statements/2 emits exactly these operations and no others" do
      for prefix <- ["public", "machines_alt"] do
        # `Enum.uniq/1`: the 10 safety-net ALTERs all collapse to the same
        # `{"ALTER TABLE", "phoenix_kit_machines"}` pair under `operation/1`
        # (which drops the column each ALTER adds) — their exact count of
        # 10 is separately asserted below and pinned in full by the
        # frozen-text test above. Every other object here is uniquely
        # named, so uniq changes nothing for them.
        actual = Migrations.up_statements(prefix) |> Enum.map(&operation/1) |> Enum.uniq()

        assert Enum.sort(actual) == Enum.sort(@up_operations),
               """
               up_statements(#{inspect(prefix)}) does not emit the expected set of
               operations.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(@up_operations))}
               missing:    #{inspect(Enum.sort(@up_operations) -- Enum.sort(actual))}

               Every statement this chain emits runs against a core-created
               table. Adding one is a chain version (V2+), not something to
               slip past this list.
               """
      end
    end

    # `operation/1` collapses all 10 safety-net ALTERs to the same
    # `{"ALTER TABLE", "phoenix_kit_machines"}` pair, so the operation-set
    # check above only proves at least one exists — the real count of 10 is
    # asserted here (and pinned exactly, in full, by the frozen-text test).
    test "the safety-net ALTER count is exactly 10, all against phoenix_kit_machines" do
      alters =
        Migrations.up_statements()
        |> Enum.filter(&String.starts_with?(&1, "ALTER TABLE"))

      assert length(alters) == 10

      for stmt <- alters do
        assert stmt =~ "public.phoenix_kit_machines "
      end
    end

    # Core's manifest for the 3 machine tables' index/constraint objects,
    # not a hand-typed list — a hand-typed list is maintained by the same
    # hand that adds a statement, so it catches a slip but never a
    # deliberate one; the manifest is written on core's side, so this fails
    # both when the chain emits an object core does not declare AND when
    # core declares an object the chain stopped adopting.
    test "up_statements/2 emits exactly the index/constraint operations core's manifest declares for the 3 machine tables" do
      for prefix <- ["public", "machines_alt"] do
        actual =
          Migrations.up_statements(prefix, 1)
          |> Enum.reject(
            &(String.starts_with?(&1, "CREATE TABLE") or
                String.starts_with?(&1, "ALTER TABLE") or
                String.starts_with?(&1, "COMMENT ON TABLE"))
          )
          |> Enum.map(&operation/1)

        expected = expected_index_constraint_operations()

        assert Enum.sort(actual) == Enum.sort(expected),
               """
               up_statements(#{inspect(prefix)}, 1) does not emit the operation set
               core's ExpectedSchema declares for the 3 machine tables' indexes and
               constraints.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(expected))}
               missing:    #{inspect(Enum.sort(expected) -- Enum.sort(actual))}
               """
      end
    end

    test "the 2 real unique indexes are present, and only them" do
      unique_indexes =
        Migrations.up_statements()
        |> Enum.filter(&String.starts_with?(&1, "CREATE UNIQUE INDEX"))
        |> Enum.map(&operation/1)
        |> Enum.map(&elem(&1, 1))
        |> Enum.sort()

      assert unique_indexes == [
               "idx_machine_operations_unique",
               "idx_machine_type_assignments_unique"
             ]
    end

    defp expected_index_constraint_operations do
      machine_tables = @machine_tables

      ExpectedSchema.objects("public")
      |> Enum.filter(fn object ->
        case object.check do
          {_kind, %{table: table}} ->
            table in machine_tables and object.class in [:index, :constraint] and
              Map.get(object, :presence) == :required

          _ ->
            false
        end
      end)
      |> Enum.map(fn object ->
        name = object.check |> elem(1) |> Map.fetch!(:name)

        case object.class do
          :constraint -> {"DO", name}
          :index -> {index_verb(object.create), name}
        end
      end)
    end

    defp index_verb(create) do
      if String.starts_with?(create, "CREATE UNIQUE INDEX"),
        do: "CREATE UNIQUE INDEX",
        else: "CREATE INDEX"
    end

    defp strip_referential_actions(statement) do
      String.replace(
        statement,
        ~r/ON\s+(DELETE|UPDATE)\s+(CASCADE|RESTRICT|NO\s+ACTION|SET\s+NULL|SET\s+DEFAULT)/i,
        "ON <referential action>"
      )
    end

    test "the referential-action strip does not blind the destructive scan" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      mutant =
        "ALTER TABLE public.phoenix_kit_machine_type_assignments ADD CONSTRAINT x FOREIGN KEY (machine_uuid) " <>
          "REFERENCES public.phoenix_kit_machines(uuid) ON DELETE CASCADE; DROP TABLE public.phoenix_kit_machine_type_assignments"

      assert strip_referential_actions(mutant) =~ forbidden

      assert strip_referential_actions("DELETE FROM public.phoenix_kit_machines") =~ forbidden
      assert strip_referential_actions("TRUNCATE public.phoenix_kit_machines") =~ forbidden
    end

    test "no statement anywhere in the data-level chain can drop a table, truncate, or delete rows" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      for prefix <- ["public", "machines_alt"] do
        for stmt <- Migrations.up_statements(prefix) do
          refute strip_referential_actions(stmt) =~ forbidden,
                 "up_statements(#{inspect(prefix)}) contains: #{stmt}"
        end

        for target <- [0, 1] do
          for stmt <- Migrations.down_statements(prefix, target) do
            refute strip_referential_actions(stmt) =~ forbidden,
                   "down_statements(#{inspect(prefix)}, #{target}) contains: #{stmt}"
          end
        end
      end
    end

    # `{verb, object}` for one statement. The DO block is identified by the
    # constraint it adds, since its verb says nothing about its target.
    defp operation(statement) do
      normalized = statement |> String.replace(~r/\s+/, " ") |> String.trim()

      if String.starts_with?(normalized, "DO ") do
        [_, constraint] = Regex.run(~r/ADD CONSTRAINT (\w+)/, normalized)
        {"DO", constraint}
      else
        [_, verb, object] =
          Regex.run(
            ~r/^(CREATE UNIQUE INDEX|CREATE INDEX|CREATE TABLE|COMMENT ON TABLE|DROP TABLE|DROP INDEX|TRUNCATE|DELETE FROM|ALTER TABLE)(?: IF NOT EXISTS)? (?:\w+\.)?(\w+)/,
            normalized
          )

        {verb, object}
      end
    end
  end

  describe "what reaches the database is what the tests above inspect" do
    # The tests above read `up_statements/2` and `down_statements/2`. The
    # database gets `up/1` and `down/1`. Nothing connected the two, so a
    # literal `execute("DROP TABLE ...")` written straight into `up/1` would
    # have passed every one of them — the guard was watching the data while
    # the function did the work.
    @source "lib/phoenix_kit_manufacturing/migrations.ex"

    test "neither direction executes SQL of its own" do
      source = File.read!(@source)

      refute source =~ ~r/execute\(/,
             """
             #{@source} calls execute/1 with an argument of its own.

             Every DDL statement this chain runs via execute/1 must come from
             up_statements/2 or down_statements/2, because those are what the
             tests above compare against their expected content. A statement
             executed directly (rather than piped in via &execute/1) is
             invisible to all of them. (up/1's own ensure_extension!/1 and
             ensure_uuid_v7_function/1 calls are unaffected by this check —
             they run their own idempotent setup outside of execute/1
             entirely, and are exercised for real by
             migrations_data_safety_test.exs instead.)
             """

      assert length(Regex.scan(~r/&execute\/1/, source)) == 2,
             "expected exactly two `&execute/1` references — one per direction — " <>
               "in #{@source}"
    end

    test "each direction executes its own builder" do
      source = File.read!(@source)

      assert source =~ ~r/up_statements\(opts\.version\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "up/1 no longer pipes up_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what the up_statements-based tests above check"

      assert source =~ ~r/down_statements\(opts\.version\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "down/1 no longer pipes down_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what `down/1 emits exactly the marker " <>
               "bookkeeping` checks"
    end

    # Scoped to the two functions' own bodies, not the whole file — the
    # moduledoc legitimately discusses "never drops a table" in prose, which
    # a whole-file, case-insensitive scan would flag as a false positive on
    # the English word rather than a SQL token.
    test "up/1 and down/1 themselves contain no DROP/TRUNCATE/DELETE token" do
      source = File.read!(@source)

      [up_body] = Regex.run(~r/def up\(.*?\n  end\n/s, source)
      [down_body] = Regex.run(~r/def down\(.*?\n  end\n/s, source)

      for {name, body} <- [{"up/1", up_body}, {"down/1", down_body}] do
        refute body =~ ~r/DROP|TRUNCATE|DELETE/i,
               "#{name}'s own body in #{@source} contains a DROP/TRUNCATE/DELETE token"
      end
    end
  end

  describe "V1 stays aligned with core's manifest (while core audits the tables)" do
    alias PhoenixKit.Migrations.ExpectedSchema
    alias PhoenixKitManufacturing.Schemas.Machine

    # `phoenix_kit_machine_type_assignments`/`phoenix_kit_machine_operations`
    # have no varchar column of their own — only `phoenix_kit_machines` has
    # a width-backed schema.
    @width_schemas %{"phoenix_kit_machines" => Machine}

    # The lesson phoenix_kit_legal paid for once (three disagreeing DDLs of
    # one table): never a second copy of a width. Parsed back out of each
    # CREATE rather than trusted, so a hard-coded number slipped into
    # up_statements/2 instead of a schema's column_widths/0 fails here even
    # though the two happen to agree today.
    test "every varchar width in the CREATE is phoenix_kit_machines' schema's column_widths/0" do
      statements = Migrations.up_statements("public", 1)

      for {table, schema} <- @width_schemas do
        columns = v1_columns(statements, table)

        parsed =
          columns
          |> Enum.filter(fn {_col, %{type: type}} -> type =~ "character varying" end)
          |> Map.new(fn {col, %{type: type}} ->
            [_, width] = Regex.run(~r/character varying\((\d+)\)/, type)
            {String.to_existing_atom(col), String.to_integer(width)}
          end)

        assert parsed == schema.column_widths(),
               """
               #{table}: the CREATE widths and #{inspect(schema)}.column_widths/0 disagree.

               parsed from DDL: #{inspect(parsed)}
               declared:        #{inspect(schema.column_widths())}
               """
      end
    end

    # Core's V144 baseline still creates these tables and core's
    # ExpectedSchema audits that shape, so until the first shape-changing
    # chain version the two DDLs must agree — with NO documented exception
    # (unlike customer_support's `changed_by_uuid`): V144's source, core's
    # manifest, and this chain's V1 all agree byte-for-byte today.
    test "every column core declares matches V1's, in full, for every table" do
      statements = Migrations.up_statements("public", 1)

      for table <- @machine_tables do
        core = core_columns(table)
        ours = v1_columns(statements, table)

        assert Map.keys(ours) -- Map.keys(core) == [],
               "#{table}: V1 creates columns core's manifest does not declare: " <>
                 inspect(Map.keys(ours) -- Map.keys(core))

        assert Map.keys(core) -- Map.keys(ours) == [],
               "#{table}: V1 does not create columns core's manifest declares: " <>
                 inspect(Map.keys(core) -- Map.keys(ours))

        for {column, expected} <- core do
          assert Map.fetch!(ours, column) == expected,
                 """
                 #{table}.#{column}: V1 and core's manifest disagree on the column's shape.

                 V1:              #{inspect(Map.fetch!(ours, column))}
                 core's manifest: #{inspect(expected)}

                 V1 is an adoption and must be shape-identical to core's
                 baseline. A deliberate change is a chain version (V2+).
                 """
        end
      end
    end

    # `%{type, default, not_null}` per column, from the newest revision.
    defp core_columns(table) do
      prefix = "column:#{table}."

      ExpectedSchema.objects("public")
      |> Enum.filter(&(&1.class == :column and String.starts_with?(&1.id, prefix)))
      |> Map.new(fn object ->
        {_version, shape} = List.last(object.revisions)

        {String.replace_prefix(object.id, prefix, ""),
         %{type: shape.type, default: shape.default, not_null: shape.not_null}}
      end)
    end

    # The same shape, parsed back out of the CREATE TABLE V1 emits for
    # `table`.
    defp v1_columns(statements, table) do
      create = table_create(statements, table)

      ~r/^\s*"(\w+)"\s+(.+?),?$/m
      |> Regex.scan(create)
      |> Map.new(fn [_line, name, definition] -> {name, parse_column(definition)} end)
    end

    defp table_create(statements, table) do
      Enum.find(
        statements,
        &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} (")
      )
    end

    defp parse_column(definition) do
      {definition, not_null} =
        case String.replace_suffix(definition, " NOT NULL", "") do
          ^definition -> {definition, false}
          trimmed -> {trimmed, true}
        end

      case String.split(definition, " DEFAULT ", parts: 2) do
        [type] -> %{type: type, default: nil, not_null: not_null}
        [type, default] -> %{type: type, default: default, not_null: not_null}
      end
    end
  end
end
