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
{:phoenix_kit_manufacturing, "~> 0.2"}
```

Then apply the module's tables and enable it in **Admin → Modules**:

```bash
mix deps.get
mix phoenix_kit.update
```

## Development

See [`AGENTS.md`](AGENTS.md) for architecture, conventions, testing, and the
release checklist.

## License

MIT — see [LICENSE](LICENSE).
