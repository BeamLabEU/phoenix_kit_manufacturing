<!-- РЕШЕНИЯ ОРКЕСТРАТОРА ПО ОТКРЫТЫМ ВОПРОСАМ (2026-07-12) -->
> **Решения по открытым вопросам:**
> 1. Провижининг блюпринтов в реестре: при невозможности (нет пользователей/БД) — тихо пропустить и ПОВТОРЯТЬ ПОПЫТКУ в начале каждого do_reload, пока блюпринты не появятся; никаких активных хук-ретраев.
> 2. Сид пользователя в test_helper manufacturing — ОСТАВИТЬ (детерминизм интеграционных тестов + creator для провижининга).
> 3. C11: семантику create_schema СВЕРИТЬ ПО ИСХОДНИКУ PhoenixKit.Migrations перед использованием (шаг задачи, не допущение).
> 4. PR-ветки: по прецеденту PR#1 — из main (warehouse: из локальной master, base upstream main); отдельные топик-ветки не заводим; перед push — обязательная проверка divergence.
> 5. Пин ядра в модулях: оставить текущий + комментарий-placeholder «bump to >= 1.7.<N> после публикации V143»; фактический бамп — мейнтейнер при релизе.
> 6. Зависимость PR manufacturing → PR locations подтверждена (PlacePicker/pk_dep) — порядок мерджа зафиксировать в обоих PR-телах.

> **ОБЯЗАТЕЛЬНЫЕ ПРАВКИ ПО ИТОГАМ РЕВЬЮ ПЛАНА (2026-07-12, GLM-5.2@Max + Sonnet 5; проверены по коду):**
> 1. **[major, GLM] Data-gap внешних V1-хостов**: V143 переносит только схему; перенос legacy-данных (machine_types→entities) НЕ воспроизводится, а его код удаляется в C3. Решение: PR manufacturing явно скоупируется «fresh-install; upgrade V1-хостов с данными — по инструкции», и в dev_docs добавляется LEGACY_DATA_MIGRATION.md — самодостаточная инструкция переноса (шаги + ссылка на git-коммит с прежним V5-кодом конверсии). Задача C3 дополняется созданием этого документа ДО удаления кода.
> 2. **[major, GLM] C10: убрать project_eval-вариант репетиции** — Ecto.Migration.execute/1 работает только внутри runner-процесса Migrator; голый project_eval молча не применяет DDL. Репетиция — только mix phoenix_kit.update ЛИБО Ecto.Migrator.up по образцу ensure_current (migration.ex:244-259), с пост-верификацией каждого объекта probe-style SQL.
> 3. **[major, GLM] C11: create_schema — факт, не исследование**: схему создаёт только V01 (v01.ex:6-9); version-scoped up(143) в непубличный prefix требует ручного CREATE SCHEMA (план уже так делает — зафиксировать как данность, create_schema: true НЕ передавать в ожидании эффекта).
> 4. **[major/MANDATORY, GLM+Sonnet] C4 — гонка провижининга блюпринтов**: unique-индекс phoenix_kit_entities_name_uidx (v17.ex:53-56) существует → (i) ensure_blueprint_entity переписать без жёсткого {:ok,_}-матча: create_entity → {:error, changeset-конфликт} → re-fetch get_entity_by_name; (ii) провижининг вызывается В НАЧАЛЕ каждого do_reload (пока все три блюпринта не подтверждены), не только в init; (iii) rescue/catch :exit вокруг — деградация, не падение supervision tree.
> 5. **[major, GLM] C5/C8 — самодостаточность тестов модулей**: после удаления собственных миграций mix test модулей требует core ≥V143, которого нет в Hex-пине до релиза. В CLAUDE.md обоих модулей — явный раздел: «интеграционные тесты до релиза ядра ≥1.7.<N> запускаются с PHOENIX_KIT_PATH=../phoenix_kit (checkout с V143)»; fallback-код в test_helper НЕ добавляем (чистота модулей).
> 6. **[minor, GLM] C1: у warehouse v01 ВОСЕМЬ индексов** (1 unique number + 7 обычных, вкл. received_at) — не потерять последний.
> 7. **[minor, GLM] C1: порядок в апгрейд-ветке** — drop_fk СТРОГО до conditional-DROP legacy-таблиц; в DO$$-EXECUTE использовать DROP TABLE ... CASCADE (устойчивость к частичному прогону).
> 8. **[minor, GLM] down(143): oговорка в moduledoc** — на V1-upgrade-хосте down дропнет join-таблицы, созданные не V143 (существовали до неё) — отметить в docstring down/1, не только в PR-теле.
> 9. **[minor, GLM] Терминология отката**: отмена V143 = down(prefix:, version: 142) (target exclusive) — унифицировать в C10 и риске №5.
> 10. **[minor, Sonnet] Дрейф divergence**: числа уже устарели (mfg +92/-0) — обязательная пересверка непосредственно перед резкой каждой PR-ветки (C0/E уже требуют — подтверждено живой проверкой).
> 11. **[minor, Sonnet] C15: зависимость PlacePicker УЖЕ жёсткая** (machine_form_live.ex:148,406,971) — в PR-теле писать «не скомпилируется без locations», шаг «подтвердить/опровергнуть» убрать.
> 12. **[minor, Sonnet] C11: ссылки на строки** — create_schema вычисляется в phoenix_kit.update.ex:440,478 (не 476-479).

# Волна C: Core-консолидация миграций manufacturing/warehouse + PR-пакет (core/locations/warehouse/manufacturing)

## Цель

Ликвидировать модульный `migration_module/0`-паттерн в `phoenix_kit_manufacturing` и `phoenix_kit_warehouse`: их таблицы переезжают в единую нумерованную цепочку миграций ядра `phoenix_kit` как новая `V143`. После консолидации — 4 draft PR (core, locations, warehouse, manufacturing) в апстрим `BeamLabEU`.

## Факты разведки (проверено заново, часть уточняет/поправляет директиву)

**Версии/свобода V143**
- upstream `BeamLabEU/phoenix_kit@main` = `c989b1a2`, `mix.exs` `@version "1.7.188"` (не 1.7.187, как в директиве — уточнение), `postgres.ex` `@current_version 142`. Единственный открытый upstream PR — `#630` (QR device-handoff login, автор `alexdont`) — миграций не трогает. **V143 свободен.**
- Диспетчеризация версии в ядре полностью по имени модуля: `change/3` делает `Module.concat([__MODULE__, "V143"]) |> apply(:up/:down, [opts])` — никакого отдельного реестра версий редактировать не нужно, кроме `@current_version` и moduledoc-списка в `postgres.ex`.
- Однострочная миграция (142→143, один шаг) НЕ получает автоматический `COMMENT ON TABLE phoenix_kit IS '143'` от `change/3` (тот пишет маркер только при `total_steps > 1`) — `v143.ex` обязан сам сделать `execute("COMMENT ON TABLE #{p}phoenix_kit IS '143'")` в конце `up/1`, как это делают `V140`/`V142`.

**Форки — уже готовы, вопреки директиве**
- `/www/phoenix_kit`: `origin` = `https://github.com/timujinne/phoenix_kit.git` (наш форк, `isFork: true`, `parent: BeamLabEU/phoenix_kit`) — форк уже существует и `origin` уже указывает на него. Отдельный remote `alexdont` тоже есть, но не используется. **Форк создавать не нужно** — пункт директивы устарел.
- Локальный `main` (`5ec84e14`, "1.7.179") == `origin/main` (0/0 разница) и является чистым подмножеством `upstream/main` (0 своих / 56 чужих коммитов — не дивергенция, просто отстаёт). Ветку волны резать от `upstream/main` (см. директиву), не от `main`/`squash-migrations` (текущая ветка, с незакоммиченным WIP `SQUASH_MIGRATIONS_TASK.md` — не трогать).
- `phoenix_kit_locations`, `phoenix_kit_manufacturing`, `phoenix_kit_warehouse` — форки под `timujinne` **тоже уже существуют**, `origin` уже наш во всех трёх. Аналогично не требуют создания.

**Состояние трёх модульных репозиториев (git)**
| Репозиторий | Локальная ветка | vs `origin/<br>` | vs `upstream/main` | Примечание |
|---|---|---|---|---|
| `phoenix_kit_locations` | `main` | +30/-0 | +30/-0 (origin==upstream) | чистый, не дивергирован |
| `phoenix_kit_manufacturing` | `main` | +90/-0 | +87/-0 | `origin/main` сам на 3 коммита позади `upstream/main` (чистое подмножество, не дивергенция) |
| `phoenix_kit_warehouse` | **`master`** (!) | vs `origin/main`: +43/-0 | vs `upstream/main`: +39/-0 | **несовпадение имени ветки**: локально чекаут на `master`, а у `origin`/`upstream` дефолтная ветка — `main`. `origin/main` и `upstream/main` оба являются предками `master` (`git merge-base --is-ancestor` = true для обоих) — не дивергенция, просто локальная ветка названа иначе. При пуше/PR использовать `master` → base `main`, не путать с несуществующим `origin/master`. |

Все три репо: `origin/main` — чистое подмножество `upstream/main` (0 «своих» коммитов при `git rev-list --left-right --count origin/main...upstream/main`) — риска «PR из протухшего локального main» (см. память) в данный момент нет, но проверять этот же командой перед резкой PR-веток обязательно (могло измениться за время выполнения волны).

**Что реально опубликовано на Hex (критично для объёма апгрейд-веток)**
- `phoenix_kit_manufacturing` на Hex: **только `0.2.0`** (опубликован 2026-07-10). На теге `0.2.0` файл `migrations/machines.ex` имеет `@current_version 1` — т.е. опубликованная версия соответствует **чистому V1**: `phoenix_kit_machines` без паспортных колонок/soft-location, `phoenix_kit_machine_type_assignments` с **живым FK** на `machine_type_uuid`, никаких `phoenix_kit_operations`/`phoenix_kit_machine_operations`/`phoenix_kit_defect_reasons`. Директива права насчёт «V1-формы» — подтверждено буквально.
- `phoenix_kit_warehouse` на Hex: **только `0.1.0`** (2026-07-10). На теге `0.1.0` каталога `lib/phoenix_kit_warehouse/migrations/` **вообще не существует** — `migration_module/0` и таблицы `transfers`/`min_stock` никогда не публиковались и ни на одном внешнем хосте не могли быть применены. **Вывод: апгрейд-ветка в V143 для warehouse-таблиц не нужна вообще** — это чистый fresh-install DDL (`CREATE TABLE IF NOT EXISTS`), без FK-дропов и условных дропов. Апгрейд-логика (DROP FK / conditional DROP) нужна **только** для трёх legacy-таблиц manufacturing (`machine_types` — единственная реально способная быть непустой на внешнем хосте; `operations`/`defect_reasons` теоретически не существуют ни на одном опубликованном хосте, но код держим симметричным на все три ради локальных/будущих сборок).

**Наш dev Postgres (andi)**
- `andi/mix.exs`: `phoenix_kit` сейчас **HEX**-зависимость (`{:phoenix_kit, "~> 1.7.165", override: true}`, строка `# {:phoenix_kit, path: "../phoenix_kit", override: true}` закомментирована рядом — строки 73/74). `phoenix_kit_manufacturing`/`phoenix_kit_warehouse`/`phoenix_kit_locations` — уже `path:`-зависимости (строки 83/85/86).
- Раз `phoenix_kit_manufacturing`/`warehouse` — `path:`-депы, `mix phoenix_kit.update`, запущенный ранее в этой среде, уже прогонял ЛОКАЛЬНЫЙ (не Hex) код `machines.ex`/`postgres.ex` модулей против нашей БД. Директива утверждает «наша БД уже в финальной форме» — вероятно так и есть (локальный `machines.ex` уже на V5), но это нужно фактически проверить в задаче D, а не считать данностью «machine_types/operations/defect_reasons» либо существуют-непустые, либо не существуют вовсе — код V143 обязан пережить оба случая идемпотентно.

**EntitiesRegistry (`/www/phoenix_kit_manufacturing/lib/phoenix_kit_manufacturing/entities_registry.ex`)**
- `GenServer.init/1` → `:ets.new` → `Events.subscribe_to_all_data/entities` → `do_reload()`. `do_reload/0` читает записи, никогда не создаёт. Провижининг блюпринтов сюда пока не перенесён.
- В `machines.ex` V5 провижининг — три структуры (`@blueprint_directories`, `resolve_creator_uuid!/0` — **жёстко `raise`ит** при отсутствии пользователей, `ensure_blueprint_entity/2` — get-or-create по `Entities.get_entity_by_name/1`). Внутри GenServer `init/1` жёсткий `raise` недопустим (падение всего supervision tree на голом хосте) — нужна graceful-деградация вместо raise (директива подтверждает: «rescue-деградация»).
- Ни один вызывающий код (кроме документации/тестов) не читает `Migrations.Machines`/`Migrations.Postgres` — только doc-упоминания в `entities_registry.ex`, `view_configs.ex` (manufacturing) и `min_stock_settings.ex` (warehouse) — правки чисто документационные, функционального кода не трогают.

**Тестовые обвязки**
- Manufacturing применяет модульную миграцию **один раз** в `test/test_helper.exs` (`Ecto.Migrator.up(..., PhoenixKitManufacturing.Test.MachinesMigration, log: false)`), плюс сеет одного пользователя перед этим специально под `resolve_creator_uuid!/0`. `test/phoenix_kit_manufacturing_test.exs` строки 283-293 — `describe "migration_module/0"` с двумя тестами, оба падут после удаления callback'а.
- Warehouse — **другой паттерн**: `test_helper.exs` не трогает warehouse-таблицы вообще (только core через `PhoenixKit.Migration.ensure_current/2`); вместо этого **7 файлов** сами в своём `setup do Ecto.Migrator.up(Repo, ..., MigrationsRunner, log: false) end` поднимают `phoenix_kit_warehouse_transfers`/`min_stock` через `PhoenixKitWarehouse.Test.MigrationsRunner` (обёртка над `Postgres.up/1`):
  `test/phoenix_kit_warehouse/transfers_test.exs`, `deficits_test.exs`, `min_stock_settings_test.exs`, `turnover_test.exs`, `web/transfer_form_live_test.exs`, `web/stock_live_test.exs`, `web/turnover_report_live_test.exs` — плюс сам `migrations/postgres_test.exs` (удаляется целиком).

**mix.exs пины (прецедент уже есть)**
- `phoenix_kit_warehouse/mix.exs` уже содержит прецедент нужного стиля пина под core-миграцию: `pk_dep(:phoenix_kit, "~> 1.7 and >= 1.7.182")` с комментарием «warehouse DB tables ship in core migration V140, published in phoenix_kit 1.7.182». Для V143 копируем этот стиль в оба модуля, но **точный patch-номер Hex-релиза, содержащего V143, неизвестен** (апстрим сейчас на 1.7.188, релиз с V143 будет выше) — ставим явный `TODO`/плейсхолдер, мейнтейнер подставит финальное число при публикации.
- `phoenix_kit_manufacturing/mix.exs` сейчас `pk_dep(:phoenix_kit, "~> 1.7.133")` — занижен, тоже требует бампа.

**Исторические записи, которые устаревают после консолидации**
- `phoenix_kit_manufacturing/dev_docs/DEVELOPMENT_PLAN.md` п.8: «Миграции — решено: собственный `migration_module/0`…» — решение отменяется этой волной, нужна приписка «superseded», не переписывание истории.
- `phoenix_kit_manufacturing/dev_docs/ENTITIES_MIGRATION_SPEC.md` §6/§7: «откат немыслим после V5, `down/1` `raise`ит» — с V143 это **больше не так** (core `down(143)` — полноценный, зеркальный дроп) — нужна приписка о том, что ограничение снято на уровне ядра (но см. риск ниже про upgrade-хосты).

## Риски

1. **`down(143)` корректен только для fresh-install.** На хосте, апгрейднутом с опубликованного manufacturing 0.2.0, `phoenix_kit_machine_type_assignments` существовала ДО V143 (создана старым `migration_module`); `down(143)`, зеркально дропающий её как «созданную V143», на таком хосте удалит таблицу, которую V143 не создавал. Директива явно требует «down(143) — зеркальный дроп пяти таблиц+sequence (и только их)» — делаем ровно так, но фиксируем это ограничение текстом в PR-теле, а не пытаемся изобретать умнее.
2. **`machine_types`/`operations`/`defect_reasons` conditional-DROP должен пережить и «таблицы нет вообще» (наш dev-хост, где V5 их уже дропнул), и «таблица есть и пуста» (fresh V1-хост без данных), и «таблица есть и непуста» (реальный опубликованный V1-хост с данными)** — обычный `DROP TABLE IF EXISTS ... WHERE count=0` не работает (COUNT упадёт на несуществующей таблице); нужен `DO $$ IF EXISTS(...) THEN IF (SELECT COUNT(*)...) = 0 THEN DROP ... END IF; END IF; END $$;` — по образцу идемпотентного `CHECK`-констрейнта в `V140` (`DO $$ BEGIN IF NOT EXISTS (...) THEN ALTER TABLE ... ADD CONSTRAINT ...; END IF; END $$;`).
3. **EntitiesRegistry graceful-деградация при отсутствии пользователей** — открытый вопрос дизайна (см. C4): скип-и-лог до следующего `do_reload` (событийного) или дополнительный крючок на первую регистрацию пользователя. Решает реализатор с ревьюером, оба варианта фиксируем в задаче.
4. **PlacePicker-зависимость locations → manufacturing** — часть из 87 локальных коммитов manufacturing (не запушенных) может опираться на компонент `PlacePicker`/`SpaceTree`, добавленный в 30 непушенных коммитах locations. Порядок PR: **locations перед manufacturing**. Точный коммит-diff не вскрывали (вне бюджета этой задачи) — исполнитель E-задач обязан прогнать `git log`/`grep PlacePicker` перед составлением PR-тела manufacturing.
5. **Живая dev БД мутируется в задаче D** (ОРКЕСТРАТОР) — комментарий-маркер `phoenix_kit` таблицы поменяется на `'143'` по-настоящему. Делать только после ревью `v143.ex`, с планом отката (маркер обратно на `'142'` через `down(143)`/ручной `COMMENT ON TABLE`).
6. **PgBouncer может тихо дропать часть DDL** — `v143.ex`, как и все core-миграции, ставится через `@disable_ddl_transaction true` на уровне сгенерированной host-обёртки (это делает `mix phoenix_kit.update`, не сам модуль) — но ручной прогон через Tidewave/`project_eval` в задаче D должен либо идти через реальную ecto-миграцию (не через прямой `PhoenixKit.Migrations.up/1` без транзакционного контроля), либо после прогона обязательно верифицировать каждую колонку/таблицу отдельно (как делает `probe_v5?/1` в текущем `machines.ex` — не полагаться на один SELECT).
7. **`origin`/`upstream` дивергенция могла измениться** с момента разведки (несколько часов/дней могли пройти) — каждая PR-задача (E) обязана заново прогнать `git fetch` + `git rev-list --left-right --count` перед резкой ветки, не полагаться на цифры из этого документа.

---

## C0 — [ОРКЕСТРАТОР, подготовка, без коммита] Синхронизация форков и ветка волны

Файлы: нет (только git-операции).

Что сделать:
1. Во всех 4 репо (`/www/phoenix_kit`, `/www/phoenix_kit_locations`, `/www/phoenix_kit_manufacturing`, `/www/phoenix_kit_warehouse`) — `git fetch upstream && git fetch origin`, заново прогнать `git rev-list --left-right --count <local>...upstream/main` и `...origin/main` (для warehouse: local-ветка — `master`, у remotes — `main`) — убедиться, что цифры из разведки не устарели и дивергенции (не-подмножества) не появилось.
2. В `/www/phoenix_kit`: `git checkout -b core-v143-module-tables upstream/main` (резать строго от `upstream/main`, не от локального `main`/`squash-migrations` — те устарели на 56 коммитов и содержат несвязанный WIP).
3. В `/www/phoenix_kit_manufacturing` и `/www/phoenix_kit_warehouse` (для локальной разработки/тестов против непубликованной V143) — экспортировать `PHOENIX_KIT_PATH=/www/phoenix_kit` при `mix test`, чтобы `pk_dep/3` в их `mix.exs` подменил Hex-пин на `path:` (см. существующий механизм — уже задокументирован в обоих CLAUDE.md, ничего создавать не нужно).

Проверка: `git branch --show-current` в phoenix_kit == `core-v143-module-tables`; `git log -1 --oneline` совпадает с `upstream/main` HEAD.

---

## A) Core (`/www/phoenix_kit`, ветка `core-v143-module-tables`)

### C1 — Новый файл `lib/phoenix_kit/migrations/postgres/v143.ex`

Файлы: `/www/phoenix_kit/lib/phoenix_kit/migrations/postgres/v143.ex` (новый).

Что сделать — модуль `PhoenixKit.Migrations.Postgres.V143`, стиль строго как `V140`/`V142` (не как `PhoenixKitWarehouse.Migrations.Postgres.V01` — тот паттерн-мэтчит `%{prefix: prefix}`, core использует `Map.get(opts, :prefix, "public")`):

```elixir
def up(opts) do
  prefix = Map.get(opts, :prefix, "public")
  p = prefix_str(prefix)
  ...
  execute("COMMENT ON TABLE #{p}phoenix_kit IS '143'")
end
```

Пять объектов в финальной (V5-эквивалентной) форме, каждый идемпотентен:

1. **`phoenix_kit_machines`** — `CREATE TABLE IF NOT EXISTS` с V1-базовыми колонками (`name, code, manufacturer, serial_number, description, location_note, status, data, metadata` + timestamps) + `CREATE INDEX IF NOT EXISTS idx_machines_status`; затем 10× `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` для паспортных колонок V2 (`model, manufacture_year, commissioned_on, warranty_until, to_last_on, to_interval_days, to_next_on, notes, location_uuid, space_uuid`) + `CREATE INDEX IF NOT EXISTS idx_machines_location`. Точные типы — списать из `machines.ex` строк 324-422 (уже проверено).
2. **`phoenix_kit_machine_type_assignments`** — `CREATE TABLE IF NOT EXISTS` **без** FK на `machine_type_uuid` (только `machine_uuid UUID NOT NULL REFERENCES ...phoenix_kit_machines(uuid) ON DELETE CASCADE`, `machine_type_uuid UUID NOT NULL` — soft-ref, без REFERENCES) + unique index `(machine_uuid, machine_type_uuid)` + index на `machine_type_uuid`; затем `drop_fk_constraint(p, prefix, "phoenix_kit_machine_type_assignments", "machine_type_uuid")` — обязательный вызов: на реальном опубликованном V1-хосте эта таблица уже существует с живым FK, только сама эта строка его снимет.
3. **`phoenix_kit_machine_operations`** — `CREATE TABLE IF NOT EXISTS`, тот же soft-ref паттерн на `operation_uuid` (никогда не публиковался ни на одном хосте с FK — но `drop_fk_constraint` всё равно вызвать для симметрии/безопасности) + unique index `(machine_uuid, operation_uuid)` + index на `operation_uuid`.
4. **Legacy directory tables** (`phoenix_kit_machine_types`, `phoenix_kit_operations`, `phoenix_kit_defect_reasons`) — **не создаются**. Только условный дроп, реализованный как `DO $$ ... $$` блок на каждую (реализовать хелпер `maybe_drop_if_empty(p, table)`):
   ```sql
   DO $$
   BEGIN
     IF EXISTS (SELECT 1 FROM information_schema.tables
                WHERE table_schema = '<prefix>' AND table_name = '<table>')
     THEN
       IF (SELECT COUNT(*) FROM <p><table>) = 0 THEN
         EXECUTE 'DROP TABLE <p><table>';
       ELSE
         RAISE NOTICE '<table> is non-empty — left in place, see PR for manual migration';
       END IF;
     END IF;
   END $$;
   ```
   (Синтаксис поправить под реальный `execute/1` + интерполяцию `p`/`prefix` — по образцу идемпотентного `CHECK`-констрейнта в `V140`, строки 72-85.)
5. **`phoenix_kit_warehouse_transfers`** + `phoenix_kit_warehouse_transfers_number_seq` — **чистый fresh-install DDL**, никакой апгрейд-логики не нужно (0.1.0 на Hex не содержал этих таблиц вообще — см. факты). Скопировать 1:1 DDL из `phoenix_kit_warehouse/lib/phoenix_kit_warehouse/migrations/postgres/v01.ex` строк 6-70 (sequence + таблица + 7 индексов), **кроме** финальной строки `COMMENT ON TABLE ...phoenix_kit_warehouse_stock IS '1'` — версионный маркер теперь только на `phoenix_kit` (core), не дублируется на `warehouse_stock`.
6. **`phoenix_kit_warehouse_min_stock`** — 1:1 из `v02.ex` строк 7-20 (таблица + unique index на `item_uuid`), без своего `COMMENT ON TABLE`.

`down(opts)` — зеркальный дроп **только** этих пяти объектов (в FK-безопасном порядке: `machine_operations`, `machine_type_assignments`, `machines`, `warehouse_min_stock`, `warehouse_transfers`+sequence), плюс `COMMENT ON TABLE #{p}phoenix_kit IS '142'`. **Не трогает** `phoenix_kit_machine_types`/`operations`/`defect_reasons` — они не в собственности V143 (см. риск №1 — задокументировать явно в moduledoc `down/1`, как V142's rollback-комментарий, только без «not supported», а с уточнением «пары join-таблиц на upgrade-хостах могут предшествовать V143»).

Хелперы `prefix_str/1`, `fk_constraint_name/3`, `drop_fk_constraint/4` — портировать 1:1 из `machines.ex` строк 897-926 (уже проверенный, работающий через catalog-lookup код) в приватные функции `v143.ex`.

Moduledoc — по образцу `V142`: короткое описание, явно указать «Consolidates tables previously created by `phoenix_kit_manufacturing`'s and `phoenix_kit_warehouse`'s own `migration_module/0` into core's migration chain — see PR body for the manual-migration note on non-empty legacy directory tables.»

Проверка:
```bash
cd /www/phoenix_kit && mix compile --warnings-as-errors
```
Плюс ручной прогон против свежей пустой БД (или временной схемы, см. C11) — все 5 таблиц + sequence на месте, `down` их убирает и возвращает маркер на `142`.

### C2 — Вписать V143 в `postgres.ex`

Файлы: `/www/phoenix_kit/lib/phoenix_kit/migrations/postgres.ex`.

Что сделать:
- `@current_version 142` → `143`.
- В верхнем moduledoc-списке версий: снять «⚡ LATEST» с `### V142`, добавить `### V143 - Manufacturing/Warehouse module tables consolidation ⚡ LATEST` (короткий буллет-список: 5 объектов, ссылка на «upgrade path for hosts on published manufacturing 0.2.0 (V1)» — по образцу существующих записей V140/V142, строки 532-557).
- **CHANGELOG.md ядра НЕ трогать** (директива + память `feedback_phoenix_kit_changelog.md`) — отметить это явно в PR-теле (C12).
- `Module.concat`-диспетчеризация подхватит `V143` автоматически по имени файла/модуля — никакой отдельный список версий редактировать не нужно (проверено в C0-разведке). `version_checks/0` (используется только `heal_version_comment/2` для исторического бага V83) — трогать не нужно, это не общий механизм «на каждую версию».

Проверка: `mix compile --warnings-as-errors`; `PhoenixKit.Migrations.Postgres.current_version() == 143` (через `iex -S mix` или `project_eval`, если репо подключено как path-dep где-то).

---

## B) Manufacturing (`/www/phoenix_kit_manufacturing`, ветка от `upstream/main` или продолжение текущего `main` — на усмотрение E, см. открытый вопрос)

### C3 — Удалить модульную миграцию, снять `migration_module/0`

Файлы:
- Удалить: `lib/phoenix_kit_manufacturing/migrations/machines.ex` (984 строки) целиком.
- Править: `lib/phoenix_kit_manufacturing.ex` — убрать `@impl PhoenixKit.Module def migration_module, do: PhoenixKitManufacturing.Migrations.Machines` (строки 79-80) и moduledoc-упоминание (строки 14-16, переписать на «tables are created by PhoenixKit core (V143); the module ships no migrations of its own»).
- Править (только doc-комментарии, без функциональных изменений): `lib/phoenix_kit_manufacturing/entities_registry.ex` строки 9-12 («provisioned by `PhoenixKitManufacturing.Migrations.Machines` V5» → «provisioned by this registry's own idempotent `init/1` — see below»), `lib/phoenix_kit_manufacturing/view_configs.ex` строки 8-10 (упоминание «reopening `Migrations.Machines`» больше не актуально — переформулировать как «core owns the module's tables now; a standalone preferences table would need its own core PR»).

Проверка: `grep -rn "Migrations.Machines" lib/` — пусто; `mix compile --warnings-as-errors`.

### C4 — Перенос провижининга блюпринтов в `EntitiesRegistry`

Файлы: `lib/phoenix_kit_manufacturing/entities_registry.ex`.

Что сделать:
- Портировать из удалённого `machines.ex` (уже вырезать перед этим коммитом C3, либо держать патч единым diff'ом C3+C4 — на усмотрение реализатора, но задача логически одна): `@blueprint_directories` (три спеки `machine_type`/`operation`/`defect_reason`, строки 543-601 исходника), `ensure_blueprint_entity/2` (строки 674-696).
- `resolve_creator_uuid!/0` **переписать без `raise`** — вместо `Auth.get_first_admin_uuid() || Auth.get_first_user_uuid() || raise(...)` вернуть `{:ok, uuid} | :no_users`; на `:no_users` — `Logger.warning`, пропустить провижининг этого прохода целиком (пустая ETS-запись для трёх kind'ов, как сейчас делает `build_kind/2` при отсутствующей entity — уже есть готовый fallback-паттерн `[{{:list, kind}, []}]`).
- Вызов провижининга — из `init/1`, **до** первого `do_reload()` (директива: «идемпотентный get-or-create при первом do_reload») — обернуть в `rescue`/`catch :exit` (мирроринг существующего модульного соглашения «rescues Postgrex.Error :undefined_table» для случая, когда core-таблицы entities ещё не смигрированы на свежем хосте) — не блокировать старт GenServer/supervision tree ни при каком исходе.
- **Открытый вопрос дизайна (не решать за реализатора, зафиксировать оба варианта на ревью):** при `:no_users` — (a) оставить как «до следующего события PubSub» (пассивная деградация, соответствует текущему поведению `build_kind/2` для отсутствующей entity) или (b) добавить ретрай-крючок на первую регистрацию пользователя, если у `PhoenixKit.Users.Auth` есть подходящий PubSub-топик. Выбор + обоснование — в PR-теле manufacturing (C15).

Проверка: `mix test --only integration` (после C6, с `PHOENIX_KIT_PATH` на core-волновую ветку) — `entities_registry_test.exs` зелёный; ручной запуск с пустой БД (0 пользователей) — приложение стартует без падения, `EntitiesRegistry.list(:machine_type)` возвращает `[]`.

### C5 — Тестовая обвязка manufacturing

Файлы:
- Удалить: `test/phoenix_kit_manufacturing/migrations/machines_test.exs`, `test/support/machines_migration.ex`.
- Править `test/test_helper.exs`: убрать блок `Ecto.Migrator.up(PhoenixKitManufacturing.Test.Repo, ..., PhoenixKitManufacturing.Test.MachinesMigration, log: false)` (строки 139-144) — таблицы теперь создаёт единственный `PhoenixKit.Migration.ensure_current(PhoenixKitManufacturing.Test.Repo, log: false)`, который уже вызывается выше по файлу. **Проверить и решить**, нужен ли по-прежнему предварительный сид одного пользователя (строки про `resolve_creator_uuid!` — сейчас сидит юзера ДО миграции ради неё) — раз провижининг блюпринтов переехал в `EntitiesRegistry.init/1` (C4, graceful-деградация без raise), тест-хелпер, возможно, больше не обязан сидить пользователя заранее; если какие-то интеграционные тесты (`entities_registry_test.exs` и др.) полагаются на готовые blueprint-entities к моменту своего `setup`, нужно явно вызвать провижининг (или `EntitiesRegistry.reload()`) там, а не в общем `test_helper.exs`.
- Править `test/phoenix_kit_manufacturing_test.exs`: удалить `describe "migration_module/0"` целиком (строки 283-293, два теста + `alias`).

Проверка:
```bash
cd /www/phoenix_kit_manufacturing && PHOENIX_KIT_PATH=/www/phoenix_kit mix test
```
(нужен path-override на core-волновую ветку — Hex ещё не содержит V143). Все зелёные, ноль упоминаний `Migrations.Machines` в `test/`.

### C6 — CLAUDE.md, mix.exs, dev_docs decision-record

Файлы:
- `CLAUDE.md` (он же `AGENTS.md`) — секция «Database & migrations»: переписать по образцу `phoenix_kit_locations/AGENTS.md` («This repo ships no production migrations — all runtime tables are created by phoenix_kit core (V143)… blueprint entities for machine_type/operation/defect_reason are provisioned by `EntitiesRegistry.init/1` at boot, idempotent get-or-create — not by migration DDL»). Также пункт 5 в «How it works» («Tables are applied by `mix phoenix_kit.update`, which discovers this module's `migration_module/0`…») переписать на «Tables are created by PhoenixKit core (V143); this module ships no migrations of its own.» Убрать таблицу колонок/rollback-абзац (устарел — вся эта информация теперь живёт в core `v143.ex` moduledoc).
- `mix.exs` — `pk_dep(:phoenix_kit, "~> 1.7.133")` → `pk_dep(:phoenix_kit, "~> 1.7 and >= 1.7.<TODO>")` с комментарием-прецедентом (как в warehouse): `# The manufacturing DB tables ship in core migration V143, published in phoenix_kit 1.7.<TODO> — TODO(maintainer): confirm exact patch version at publish time (upstream currently at 1.7.188).`
- `dev_docs/DEVELOPMENT_PLAN.md` п.8 — приписка `[SUPERSEDED 2026-07-12]: миграции консолидированы в core V143, migration_module/0 удалён — см. PR core-v143-module-tables.` (не переписывать исходный текст).
- `dev_docs/ENTITIES_MIGRATION_SPEC.md` §6/§7 — приписка о том, что с V143 `down/1` больше не «raise», а полноценный (но с оговоркой про upgrade-хосты — см. риск №1 выше), ссылка на core PR.

Проверка: `mix docs` не падает (если есть alias); визуально свериться с `phoenix_kit_locations/AGENTS.md` секцией «Database & Migrations» на предмет стиля.

---

## C) Warehouse (`/www/phoenix_kit_warehouse`, локальная ветка `master` — см. риск про имя ветки)

### C7 — Удалить модульную миграцию, снять `migration_module/0`

Файлы:
- Удалить: `lib/phoenix_kit_warehouse/migrations/postgres.ex`, `lib/phoenix_kit_warehouse/migrations/postgres/v01.ex`, `lib/phoenix_kit_warehouse/migrations/postgres/v02.ex` (весь каталог `migrations/`).
- Править: `lib/phoenix_kit_warehouse.ex` — убрать `@impl PhoenixKit.Module def migration_module, do: PhoenixKitWarehouse.Migrations.Postgres` (строка 103) + соседний moduledoc-пункт 5 «Tables are applied by `mix phoenix_kit.update`, which discovers this module's `migration_module/0`…» → «Tables are created by PhoenixKit core (V143); this module ships no migrations of its own.»
- Править (doc-комментарий): `lib/phoenix_kit_warehouse/min_stock_settings.ex` строки 5-6 «Backed by `phoenix_kit_warehouse_min_stock` (introduced in `PhoenixKitWarehouse.Migrations.Postgres.V02` / T16)» → «…(introduced in core PhoenixKit migration V143)».

Проверка: `grep -rn "Migrations.Postgres" lib/` — пусто; `mix compile --warnings-as-errors`.

### C8 — Тестовая обвязка warehouse (7 файлов + 2 удаления)

Файлы — убрать `alias PhoenixKitWarehouse.Test.MigrationsRunner` + `setup do Ecto.Migrator.up(Repo, :os.system_time(:microsecond), MigrationsRunner, log: false) end`-блок (сами тела тестов не трогать — таблицы теперь поднимает общий `PhoenixKit.Migration.ensure_current/2` из `test_helper.exs`, который создаёт core-таблицы один раз на весь прогон):
- `test/phoenix_kit_warehouse/transfers_test.exs` (строки 9, 20-23)
- `test/phoenix_kit_warehouse/deficits_test.exs`
- `test/phoenix_kit_warehouse/min_stock_settings_test.exs`
- `test/phoenix_kit_warehouse/turnover_test.exs`
- `test/phoenix_kit_warehouse/web/transfer_form_live_test.exs`
- `test/phoenix_kit_warehouse/web/stock_live_test.exs`
- `test/phoenix_kit_warehouse/web/turnover_report_live_test.exs`

Удалить целиком:
- `test/phoenix_kit_warehouse/migrations/postgres_test.exs`
- `test/support/migrations_runner.ex`

Проверка:
```bash
cd /www/phoenix_kit_warehouse && PHOENIX_KIT_PATH=/www/phoenix_kit mix test
```
Все 7 правленых файлов зелёные без собственного migrator-вызова; `grep -rln MigrationsRunner test/` — пусто.

### C9 — CLAUDE.md, mix.exs

Файлы:
- `CLAUDE.md`/`AGENTS.md` — секция «Database & migrations»: та же переформулировка, что в C6 (core-паттерн вместо «standalone-package pattern»); пункт 5 «How it works» аналогично.
- `mix.exs` — `pk_dep(:phoenix_kit, "~> 1.7 and >= 1.7.182")` → `pk_dep(:phoenix_kit, "~> 1.7 and >= 1.7.<TODO>")`, комментарий обновить на V143 (по образцу уже существующей формулировки про V140, просто сдвинуть номер версии и добавить TODO на точный patch).

Проверка: аналогично C6.

---

## D) Репетиция на живом dev Postgres — **ОРКЕСТРАТОР, обязательная, мутирует БД**

### C10 — [ОРКЕСТРАТОР] No-op прогон на реальной public-схеме andi

Файлы: `/www/app/mix.exs` (временная правка строк 73-74).

Что сделать:
1. Перед началом — через Tidewave (`execute_sql_query`) зафиксировать ТЕКУЩЕЕ состояние: существуют ли `phoenix_kit_machine_types`/`operations`/`defect_reasons` на нашей БД (ожидание по директиве — нет, V5 их уже дропнул), есть ли FK на `machine_type_assignments.machine_type_uuid`/`machine_operations.operation_uuid` (ожидание — нет), есть ли уже `phoenix_kit_warehouse_transfers`/`min_stock` (не факт — не гарантировано разведкой, проверить фактически). Текущий маркер `COMMENT ON TABLE phoenix_kit` (ожидание — `'142'`).
2. Правка `/www/app/mix.exs`: закомментировать строку 73 (`{:phoenix_kit, "~> 1.7.165", override: true},`), раскомментировать строку 74 (`{:phoenix_kit, path: "../phoenix_kit", override: true},`) — но `path: "../phoenix_kit"` должен резолвиться на ветку `core-v143-module-tables` (тот же чекаут `/www/phoenix_kit`, просто на нужной ветке — убедиться, что она чекаутнута перед этим шагом).
3. `mix deps.get` (пересборка lock под path-dep) → recompile → **перезапуск elixir** (память: path-dep изменения требуют `sudo /usr/bin/supervisorctl restart elixir`, hot-reload не подхватит смену источника зависимости).
4. Прогнать `mix phoenix_kit.update` (либо более точечно — через Tidewave `project_eval`, вызвав `PhoenixKit.Migrations.up(prefix: "public", version: 143)` напрямую, чтобы не тянуть весь igniter-flow с интерактивными промптами/asset rebuild) на `PORT=4999` (память: не занимать порт живого сервера).
5. Верифицировать: маркер `'143'`, все 5 объектов на месте, ни одна из legacy directory tables не пересоздалась (если их не было — их и не должно появиться), warehouse-таблицы либо не изменились (если уже были), либо появились как fresh-install (если не было).
6. **Откат приготовить, но не обязательно исполнять**: если что-то пошло не так — `PhoenixKit.Migrations.down(prefix: "public", version: 142)` вручную через `project_eval`, затем откат `mix.exs` на Hex-строку + restart.

Проверка: `SELECT pg_catalog.obj_description(...) ... relname='phoenix_kit'` = `'143'`; повторный прогон `up(version: 143)` — no-op (никаких новых DDL-эффектов, маркер остаётся `'143'`).

### C11 — [ОРКЕСТРАТОР] Fresh-host репетиция в отдельной схеме

Файлы: нет (только SQL/Tidewave).

Что сделать (при живом path-dep на core-волновую ветку, продолжение C10 либо независимо):
1. `CREATE SCHEMA pk_v143_rehearsal;` через Tidewave.
2. `PhoenixKit.Migrations.up(prefix: "pk_v143_rehearsal", version: 143, create_schema: false)` (схема уже создана вручную — прочитать, требует ли `up/1` `create_schema: true` сам создавать её, или ожидает готовую — свериться с сигнатурой в `phoenix_kit.update.ex` строки 476-479, где `create_schema: create_schema` вычисляется как `prefix != "public"`).
3. Проверить построчно (как `probe_v5?/1` делает в текущем `machines.ex`) — все 5 таблиц/sequence реально созданы **под префиксом `pk_v143_rehearsal`**, а не по ошибке в `public` (частый баг с интерполяцией префикса в raw SQL).
4. `DROP SCHEMA pk_v143_rehearsal CASCADE;` — снести полностью, не оставлять мусор на dev-БД.

Проверка: до дропа — `information_schema.tables WHERE table_schema='pk_v143_rehearsal'` содержит все 5 объектов; после дропа — схема отсутствует.

---

## E) PR-пакет — 4 draft PR в апстрим `BeamLabEU`

Общая для всех четырёх задач подготовка: **заново** (не полагаясь на цифры из «Факты» выше) прогнать `git fetch upstream && git fetch origin` и `git rev-list --left-right --count <branch>...upstream/main` — если появилась дивергенция (не строгое подмножество), остановиться и разобраться, откуда взялись «чужие» коммиты, прежде чем резать PR-ветку (память: `reference_pr_branch_from_stale_local_main`).

Порядок мерджа/готовности (директива + факт про PlacePicker): **core → locations → (warehouse, manufacturing в любом порядке между собой, но manufacturing строго после locations)**. Формально это порядок готовности PR к ревью мейнтейнером, не порядок наших коммитов — все 4 PR можно открыть параллельно как draft, но в PR-теле manufacturing явно указать «depends on #<locations-PR> for PlacePicker».

### C12 — PR core: `core-v143-module-tables` → `BeamLabEU/phoenix_kit:main`

Файлы: `/www/phoenix_kit/dev_docs/pull_requests/2026/143-manufacturing-warehouse-tables-consolidation/{AGENT}_REVIEW.md` (по конвенции репозитория — см. `dev_docs/pull_requests/TEMPLATE.md`, уже существует в репо).

Что сделать:
1. `git push origin core-v143-module-tables`.
2. `gh pr create --repo BeamLabEU/phoenix_kit --base main --head timujinne:core-v143-module-tables --draft --title "V143: consolidate manufacturing/warehouse module tables into core" --body "..."`.
3. Тело PR: что вошло (5 объектов, апгрейд-ветка для V1-хостов manufacturing 0.2.0, fresh-install-only для warehouse — не публиковался с таблицами), явно **не трогали CHANGELOG.md/`@version`** (мейнтейнер сам, память `feedback_phoenix_kit_changelog.md`), риск №1 (down(143) не восстанавливает pre-existing join-таблицы на upgrade-хостах), риск про legacy non-empty tables (оставлены + инструкция ручной миграции — привести конкретные SQL-шаги или ссылку на старый `machines.ex` V5 entities-migration код как референс для тех, кому нужен полный перенос данных).
4. Отметить зависимость: локальные PR'ы `warehouse`/`manufacturing` бампают свой `pk_dep(:phoenix_kit, ...)` пин на версию, которая появится после публикации этого PR — placeholder, мейнтейнер подставит после `hex.publish`.

Проверка: `gh pr view <N> --repo BeamLabEU/phoenix_kit` показывает `draft: true`, base `main`, содержит diff только `postgres.ex` + `postgres/v143.ex` (+ review-файл).

### C13 — PR locations: существующие 30 коммитов → `BeamLabEU/phoenix_kit_locations:main`

Файлы: `/www/phoenix_kit_locations/dev_docs/pull_requests/2026/8-<slug>/{AGENT}_REVIEW.md` (следующий свободный номер после существующих `2..7` в каталоге).

Что сделать:
1. **Эта задача не про миграции** — `phoenix_kit_locations` уже на core-паттерне (V90/V122), правок для V143 не требует. Единственная причина открывать PR сейчас — 30 непушенных локальных коммитов (включая `PlacePicker`/`SpaceTree`, gettext-экстракцию), от которых зависит manufacturing (риск №4).
2. `git log upstream/main..main --oneline` (или `--stat`) — прочитать реальное содержимое 30 коммитов перед написанием PR-тела (не гадать).
3. Решить (открытый вопрос, см. ниже) — пушить ли `main` напрямую как head-ветку PR, или сначала `git checkout -b <topic-branch>` от текущего `main` и пушить его — свериться с тем, как заведены предыдущие PR (`2026/2-routing-anti-pattern` и т.п.) в этом репо, чтобы не сломать конвенцию.
4. `gh pr create --repo BeamLabEU/phoenix_kit_locations --base main --draft ...`.

Проверка: `gh pr view` — draft, base `main`, diff соответствует ровно тем 30 коммитам.

### C14 — PR warehouse: `master` → `BeamLabEU/phoenix_kit_warehouse:main`

Файлы: `/www/phoenix_kit_warehouse/dev_docs/pull_requests/2026/2-<slug>/{AGENT}_REVIEW.md` (следующий номер после существующего `1-warehouse-module`).

Что сделать:
1. Учесть branch-mismatch (см. риск): пушить `git push origin master:main` (или `-u`) — **не** пытаться пушить в несуществующий `origin/master`. Проверить `gh pr create --head timujinne:main` резолвится на нужный коммит.
2. PR включает: C7, C8, C9 (удаление модульной миграции + правка 7 тестов + CLAUDE.md/mix.exs), плюс всё остальное из 39/43 локальных коммитов, что уже готово к ревью (разведка не проверяла состав всех 39 коммитов вне рамок миграций — при составлении PR-тела реализатору стоит `git log upstream/main..master --oneline` пробежаться, что именно едет помимо волны C).
3. Тело PR — явная зависимость: `pk_dep(:phoenix_kit, ...)` пин на V143-содержащий релиз (placeholder, см. C9); ссылка на core PR (C12).

Проверка: аналогично C12/C13.

### C15 — PR manufacturing: `main` → `BeamLabEU/phoenix_kit_manufacturing:main`

Файлы: `/www/phoenix_kit_manufacturing/dev_docs/pull_requests/2026/2-<slug>/{AGENT}_REVIEW.md` (следующий номер после `1-scaffold-module`).

Что сделать:
1. Перед написанием тела — `grep -rn "PlacePicker\|SpaceTree" lib/` в manufacturing + сверить с locations' 30 коммитами (C13) — подтвердить/опровергнуть фактическую зависимость, а не полагаться на директиву без проверки.
2. PR включает C3-C6 (волна) + остальное из 87/90 локальных коммитов, готовых к ревью.
3. Тело PR: явно **«depends on BeamLabEU/phoenix_kit_locations#<N> (PlacePicker)»** и **«depends on BeamLabEU/phoenix_kit#<M> (V143)»**; риск про legacy `phoenix_kit_machine_types` non-empty на реальных внешних V1-хостах (0.2.0 опубликован, теоретически кто-то уже поставил) — инструкция ручной миграции для таких хостов (ссылка на старый V5 entities-migration код как reference-implementation, раз он удаляется из репо, но кому-то может понадобиться руками повторить).
4. Отметить снятие DEVELOPMENT_PLAN.md п.8 / ENTITIES_MIGRATION_SPEC.md §6-7 (C6) как «superseded», не «переписано».

Проверка: аналогично.

---

## Ограничения среды (напоминание, как в предыдущих волнах)

- `PHOENIX_KIT_PATH`, `PHOENIX_KIT_LOCATIONS_PATH` и т.п. — только для `mix test`/`mix compile` внутри модульных репо (`pk_dep/3` в их `mix.exs`), не влияют на `andi`.
- В `/www/app` источник `phoenix_kit` переключается вручную комментированием строки 73/74 `mix.exs` — не через env var.
- `mix phoenix_kit.update` — единственная команда для применения ядра к andi (память `feedback_phoenix_kit_update.md`) — никогда не разбивать на `gen.migration` + ручной `Ecto.Migrator.run`.
- После смены path-dep источника в `/www/app` — обязателен `sudo /usr/bin/supervisorctl restart elixir` (память `feedback_path_dep_reload.md`), рутинные правки самих модулей (без смены источника зависимости) — без рестарта.
- CHANGELOG.md и `@version` во всех `phoenix_kit*`-репозиториях — не трогаем, это зона мейнтейнера (память `feedback_phoenix_kit_changelog.md`).
- Коммиты/PR — без AI-атрибуции (память `feedback_no_claude_attribution.md`).
