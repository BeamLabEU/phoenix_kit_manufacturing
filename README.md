# PhoenixKit Manufacturing

Manufacturing module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

A drop-in PhoenixKit module — add it to a host app's deps and it is
auto-discovered, adding a **Manufacturing** section to the admin panel.

## Features

- **Machines reference book** — full CRUD for production machines
  (name, code, manufacturer, serial number, status, location note, plus a
  freeform `metadata` JSONB column for passport/spec fields).
- **Machine types** — a mini reference with multilang name/description,
  linked to machines many-to-many (a machine can carry several types).
- **Dashboard** with live machine / machine-type counts.
- Activity logging, centralized paths, and its own versioned database
  migrations (applied via `mix phoenix_kit.update`).

Roadmap (see [`dev_docs/DEVELOPMENT_PLAN.md`](dev_docs/DEVELOPMENT_PLAN.md)):
production orders, warehouse integration (goods issues / receipts),
dashboard widgets, and staff/project links.

## Installation

Add to your host app's `mix.exs`:

```elixir
{:phoenix_kit_manufacturing, "~> 0.4"}
```

Then apply the module's tables and enable it in **Admin → Modules**:

```bash
mix deps.get
mix phoenix_kit.update
```

## Removing this module

There is deliberately **no automated uninstall**. `PhoenixKitManufacturing.Migrations.down/1`
never drops any of the 3 `phoenix_kit_machine*` tables or a row in them, for
any target version — a host that merely removes this dependency from
`mix.exs` has not consented to deleting every machine reference-book
record and its type/operation links, and a migration whose result depended
on which packages happen to be compiled in would be nondeterministic.
Removing the data is therefore a deliberate, manual operator step, in
FK-safe order (children before parents):

```sql
-- Only after removing :phoenix_kit_manufacturing from mix.exs, and only if
-- you actually want every machine and everything linked to it gone for good.
DROP TABLE phoenix_kit_machine_operations;
DROP TABLE phoenix_kit_machine_type_assignments;
DROP TABLE phoenix_kit_machines;
```

Dropping `phoenix_kit_machines` last also removes the `pkm_schema:<N>`
version marker, which is a `COMMENT` on that table — no separate step is
needed.

If you want to keep the tables (e.g. you plan to reinstall the module
later) but stop this chain from tracking them, clear the version marker
instead:

```sql
COMMENT ON TABLE phoenix_kit_machines IS NULL;
```

## Development

See [`AGENTS.md`](AGENTS.md) for architecture, conventions, testing, and the
release checklist.

## License

MIT — see [LICENSE](LICENSE).
