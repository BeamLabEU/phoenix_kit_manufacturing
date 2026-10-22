<!-- ПРИМЕЧАНИЕ ОРКЕСТРАТОРА 2026-07-11: решения по открытым вопросам планировщика -->
> **Решения по открытым вопросам (2026-07-11):**
> 1. **`options: [string]` для `type == "select"` — ДА** (обязательное при select, иначе select бессмыслен).
> 2. **Хранение metadata-значений строками** (boolean — JSON true/false) — принято для v0.2.x; типизированная нормализация — позже.
> 3. **`manufacture_year` — принято** (читаемость рядом с датами).
> 4. **phoenix_kit_locations: PlacePicker/Attachments/full_path есть ТОЛЬКО в нашем форке**, на Hex 0.2.x их нет. Локальная разработка/тесты модуля — через `PHOENIX_KIT_LOCATIONS_PATH=../phoenix_kit_locations` (pk_dep-механизм); в хосте рантайм работает (locations уже path dep). Для upstream-PR manufacturing — зависимость: сначала PR/публикация волны locations. Зафиксировать это в описании PR.
> 5. **@disable_ddl_transaction добавляем** несмотря на инертность для module-обёрток (forward-compat + документация намерения); реальная PgBouncer-защита — контрольная точка оркестратора (проверка to_regclass после apply).
> 6. **FilterChips упрощённые** («N фильтров» + общий сброс) — принято для волны.
> 7. **Порядок секций формы**: паспорт → Types → Operations → Files → Comments — принят как в плане.
> 8. **Параметризация Comments/Attachments по kind/scope** с единственным kind=:machine сейчас — принята.

> **ОБЯЗАТЕЛЬНЫЕ ПРАВКИ ПО ИТОГАМ РЕВЬЮ ПЛАНА (2026-07-11, GLM-5.2@Max + Sonnet 5; всё проверено по коду):**
> 1. **[blocker, GLM] М15 — контракт ColumnConfig.** Колонки описывать СТРОГО по реальному контракту (`phoenix_kit_warehouse/column_config/inventories.ex:13-89`): `:id` (не :key), `:label` — zero-arity fn, `:default?`/`:sortable?`/`:filterable?` (с `?`), обязательные `:align`, `:sort_key`, `:default_dir`, `:filter_type` + `:filter_apply` (замыкания text_filter/enum_filter/numeric_range_filter/date_range_filter), для enum — `:filter_options`. Колонка `types` — только после появления `:types_csv` в enrich.
> 2. **[major, Sonnet] М1/М3/М19/М28 — version-probes проверяют ВСЁ.** Каждый `probe_vN?` обязан проверять ВСЕ структурные добавления версии (каждую новую колонку каждой изменённой таблицы, каждую новую таблицу), не один представитель — частичный PgBouncer-накат иначе маскируется навсегда (атрибут DDL-транзакции инертен для module-обёрток).
> 3. **[major, GLM] М17 — фильтры/сортировка не наследуются.** `apply_column_filters/3`, `apply_sort/3`, `apply_global_search/2`, `enrich_machines/1` — приватные функции СВОЕГО LiveView: скопировать в MachinesLive по образцу inventories_live.ex (:159, :194); fallback скрытой сортировочной колонки — `"name"` (не "number"); извлечение current_user_uuid — строки 45-47.
> 4. **[major, GLM] М25/М33 — unit-тест последнего таба.** `phoenix_kit_manufacturing_test.exs:106-111` утверждает `List.last(admin_tabs()).id == :manufacturing_machine_edit` — обновлять assertion в КАЖДОЙ задаче, добавляющей wildcard-таб (М25: operation_edit, М33: defect_reason_edit).
> 5. **[major, GLM+Sonnet] М2 — зависимость от публикации locations.** `pk_dep(:phoenix_kit_locations, ...)` без `PHOENIX_KIT_LOCATIONS_PATH` не соберётся (PlacePicker только в форке). Разработка/тесты — с PATH-override; версия пина — placeholder до публикации волны locations; в М35 — чек-пункт «PR/публикация locations — пререквизит upstream-PR manufacturing» (bump/публикация — прерогатива мейнтейнера, мы только фиксируем зависимость в описании PR).
> 6. **[major, GLM] М7 — PlacePicker внутрь `<.form>` НЕ ставить без изоляции.** Сверить с location_form_live.ex; рендерить пикер вне основной `<.form phx-change="validate">` либо гарантировать `phx-target` на всех inputs пикера — иначе каждый ввод в комбобоксе всплывает в validate формы.
> 7. **[major, GLM] М27 — save-флоу.** `sync_types_and_redirect/3` уже делает push_navigate: переписать в общий `sync_and_redirect` (sync_machine_types → sync_machine_operations → навигация), не «после типового пайплайна».
> 8. **[major, GLM] Version bump.** Добавить в Group H задачу: bump `@version` в mix.exs + assertion в `version/0`-тесте (три места по CLAUDE.md); волна = 0.3.0 (новые таблицы/функциональность, не патч).
> 9. **[minor] М12/М13→М17 (Sonnet):** фото-миниатюру не делать дважды — содержимое М13 переносится в М17 (или М13 после М17). **М9 (Sonnet):** явный механизм динамических строк field_template — raw `name="machine_type[field_template][IDX][key]"`-оверрайды на инпутах, НЕ через @form[:atom]. **М6 (Sonnet):** конфликт ключей шаблонов — подсказка «из типа X» в форме или явный комментарий. **М15/М17 (Sonnet):** location_label — батч-резолв по списку uuid (не поштучно на строку). **М10 (GLM):** чек-лист аудита копии attachments.ex на прочие упоминания Location/Space. **М5 (GLM):** `validate_format(key, ~r/^[a-z0-9_]+$/)` для ключей шаблона. **М3 (GLM):** down/1 — честно описать как полный all-or-nothing откат (version: игнорируется), без иллюзии инкрементального rollback. **М19/М28 (GLM):** нейминг `phoenix_kit_operations`/`phoenix_kit_machine_operations`/`phoenix_kit_defect_reasons` — осознанное следование конвенции мейнтейнера поверх §Б.8, оговорить в задачах. **М22 (GLM):** сравнение overrides = `Map.equal?/2` по набору И значениям.
>
> **Дополнительные решения оркестратора:**
> 9. **Форма станка остаётся single-page card** (стиль мейнтейнера v0.2) — это осознанное решение оркестратора, заменяющее формулировку §Б.7 про «вкладки-роуты» (та писалась до upstream-реализации); hidden CRUD tab-роуты при этом существуют, как у мейнтейнера.
> 10. **Нейминг таблиц следует мейнтейнеру** (`phoenix_kit_machines`-стиль без `manufacturing_`) — поверх буквы §Б.8.

## План волны v0.2.x — PhoenixKit Manufacturing (Machines: паспорт, field_template, файлы, обвязка, операции, брак)

## 0. Цель

Дореализовать поверх уже отгруженного мейнтейнером `Machines v0.2` (справочник станков + типы M2M) шесть пунктов gap-анализа §В `dev_docs/DEVELOPMENT_PLAN.md`: расширенный паспорт станка + мягкая привязка к месту (PlacePicker), `field_template` на типе станка с динамическим рендером `metadata`, файлы/фото (Attachments-паттерн), обвязка списка станков (ColumnConfig/ColumnManagement/ViewConfigs/Comments — warehouse-паттерн), справочник Операций (+ M2M со станком) и справочник Причин брака. Базис — код и стиль мейнтейнера (`lib/phoenix_kit_manufacturing/**`), наши дополнения — поверх; волна пойдёт PR-ом в upstream `BeamLabEU/phoenix_kit_manufacturing`.

Решения: `dev_docs/DEVELOPMENT_PLAN.md` §Б (пункты 1–10) и §В (таблица gap-анализа, объём волны). Расхождение с §Б, где задание явно переопределяет решение, отмечено в задаче 3 ниже (форма остаётся single-page card, не multi-tab).

## 1. Текущее состояние (файлы/строки)

- `lib/phoenix_kit_manufacturing.ex:88-198` — `admin_tabs/0`: Dashboard/Machines/Types + скрытые New/Edit-табы, приоритеты 154-161. Порядок «статичные пути → wildcard `:uuid`» уже соблюдён.
- `lib/phoenix_kit_manufacturing/machines.ex` — один контекст на всё: Machine Types CRUD (51-116), Machines CRUD (122-207), M2M `machine_type_assignments` + `sync_machine_types/3` (213-303), activity-log обвязка (316-411).
- `lib/phoenix_kit_manufacturing/schemas/machine.ex:23,56-81` — статусы `~w(active maintenance decommissioned)`, поля `name/code/manufacturer/serial_number/description/location_note/status/data/metadata`.
- `lib/phoenix_kit_manufacturing/schemas/machine_type.ex` — `name/description/status/data` (мультиязычные name/description через `data`, управляются `MultilangForm`).
- `lib/phoenix_kit_manufacturing/migrations/machines.ex:26-146` — `@current_version 1`, три таблицы (`phoenix_kit_machines`, `phoenix_kit_machine_types`, `phoenix_kit_machine_type_assignments`), нет `@disable_ddl_transaction`.
- `lib/phoenix_kit_manufacturing/web/machines_live.ex` — одна LiveView на `:index`/`:types` (диспетчеризация по `live_action`), без streams, `table_default` + `confirm_modal`.
- `lib/phoenix_kit_manufacturing/web/machine_form_live.ex` — single-page card форма, `Phoenix.LiveView` (не `PhoenixKitWeb, :live_view`, не self-wrapped layout — админ-chrome применяется автоматически), toggle-бейджи типов через `MapSet`.
- `lib/phoenix_kit_manufacturing/web/machine_type_form_live.ex` — форма типа станка, `MultilangForm` (`translatable_fields = ["name","description"]`).
- `mix.exs:70-79` — единственная зависимость `pk_dep(:phoenix_kit, "~> 1.7.133")`. Нет `phoenix_kit_locations`, `phoenix_kit_comments`, `phoenix_kit_warehouse`.
- Прецеденты (копируются, НЕ импортируются как зависимость, кроме явно отмеченного): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/{column_config.ex, column_config/inventories.ex, view_configs.ex, comments.ex, web/column_management.ex, web/components/{column_modal.ex,comments_panel.ex}}`; `/www/phoenix_kit_locations/lib/phoenix_kit_locations/{attachments.ex, web/components/files_card.ex}`. PlacePicker и `Spaces.full_path/2` — используются напрямую (см. находку №3).

## 2. Ключевые находки этого плана (важно прочитать перед стартом)

1. **Баг в `migrated_version_runtime/1`** (`migrations/machines.ex:39-55`): функция проверяет только «существует ли `phoenix_kit_machines`» и возвращает `@current_version`, если да — то есть НЕ различает, какая версия схемы реально накатана. Если просто поднять `@current_version` до 2 и добавить `ALTER TABLE`, то на хосте, где уже стоит V1, скомпилированный код увидит «таблица есть» → вернёт 2 → `mix phoenix_kit.update`'шный `run_module_migrations/1` (`/www/phoenix_kit/lib/mix/tasks/phoenix_kit.update.ex:840-866`, сравнение `current < target`) решит, что всё up-to-date, и **молча пропустит** накат V2. Это нужно исправить ДО первого бампа версии — задача М1.
2. **`@disable_ddl_transaction` на своём `migration_module` — по факту инертен** для внешних модулей. `generate_module_migration/5` (`phoenix_kit.update.ex:890-932`) генерирует host-обёртку без `@disable_ddl_transaction true` и не читает этот атрибут у нашего `Migrations.Machines` (в отличие от `phoenix_kit.gen.migration.ex:120` — та ветка только для core). Реальная защита от PgBouncer здесь — не в коде модуля, а в контроле оркестратора после `mix phoenix_kit.update` (см. память `reference_pgbouncer_migrations.md`). Атрибут всё равно добавляем (задание явно требует, forward-compat, документирует намерение), но в задаче М3 отдельно фиксируем контрольную точку проверки.
3. **PlacePicker — реальная новая mix-зависимость.** `Attachments` и весь `ColumnConfig`-стек копируются как паттерн (без runtime-зависимости от phoenix_kit_locations/phoenix_kit_warehouse). Но `PhoenixKitLocations.Web.Components.PlacePicker` (LiveComponent) и `PhoenixKitLocations.Spaces.full_path/2` — встраиваются напрямую, по прецеденту `phoenix_kit_warehouse/mix.exs:92-95` (`pk_dep(:phoenix_kit_locations, "~> 0.2")`, `extra_applications`). Аналогично добавляем `pk_dep(:phoenix_kit_comments, "~> 0.2")` для Comments-обёртки (сам `PhoenixKitComments` всё равно вызывается через `Code.ensure_loaded?/1` + `@compile {:no_warn_undefined, PhoenixKitComments}`, т.к. на хосте модуль может быть выключен). Локальная версия `phoenix_kit_locations` в `/www/phoenix_kit_locations/mix.exs` — `0.2.1`; убедиться, что PlacePicker/Attachments/`Spaces.full_path/2` действительно попали в опубликованную на Hex версию (или использовать `PHOENIX_KIT_LOCATIONS_PATH=../phoenix_kit_locations` для локальной разработки/тестов модуля, как уже делает хост в `<host-app>/mix.exs:83`).
4. **PlacePicker не восстанавливает текущий выбор при `:edit`.** По его же moduledoc (`place_picker.ex:40-56`) `:selected_location_uuid` «accepted for symmetry but not currently consumed» — виджет всегда стартует с пустым комбобоксом. Поэтому в форме станка нужен отдельный read-only summary «Текущее место: …» (через `Machines.location_label/1`, задача М6) поверх самого пикера, и сам пикер показываем свёрнутым/по кнопке «Изменить», а не всегда раскрытым — иначе редактирование существующего станка выглядит так, будто место не задано.
5. **`field_template.type == "select"` без списка опций бесполезен.** Заявленная форма `{key, label, type, unit, required}` не содержит вариантов для `select`. Решение плана: добавить необязательное поле `options: [string]`, используемое только при `type == "select"` (см. задачу М5/М10). Отмечено в открытых вопросах — подтвердить у пользователя.
6. **Хранение `metadata` по `field_template`** — упрощение: значения всех типов, кроме `boolean`, хранятся как строки (как их вводит `<input>`), `boolean` — как JSON `true/false`. Без нормализации чисел/дат в типизированный JSON (это можно сделать позже, не блокирует волну). Отмечено в открытых вопросах.
7. **`year` → `manufacture_year`.** Переименовано против буквальной формулировки §Б («год выпуска») для ясности внутри таблицы с несколькими датами (`commissioned_on`, `warranty_until`, `to_last_on`, `to_next_on`). Постгресово `year` — не зарезервированное слово, но решение сделано ради читаемости; не блокирующее, но стоит подтвердить.
8. Стиль формы станка сохраняется **single-page card** (`machine_form_live.ex`), НЕ переходит на вкладки-роуты `hidden_crud_tabs` — это явное указание задания поверх более старого пункта §Б.7 («форма — вкладки-роуты, как у internal_orders»). Новые секции (Files, Operations, Comments) — доп. блоки `<div class="divider">…</div>` внутри той же карточки, как это уже сделано для блока «Machine Types» (`machine_form_live.ex:243-275`).
9. `ColumnConfig`/`ColumnManagement`/`ViewConfigs`/`ColumnModal` подключаются **только к списку станков** (`MachinesLive`, `:index`). Types/Operations/Defect Reasons остаются на простом `table_default` (справочная кардинальность, как сейчас у Types) — это соответствует буквальной формулировке задания («для machines index»).
10. `Comments`-обёртка — только `resource_type "machine"`, только на `MachineFormLive :edit` (у `:new` нет `uuid` до сохранения).

## 3. Соглашения, которые нужно соблюдать во всех задачах

- `use Phoenix.LiveView` (не `PhoenixKitWeb, :live_view`), без self-wrapped `LayoutWrapper` — админ-chrome уже применяется автоматически (см. комментарий в `dashboard_live.ex:6-8`).
- Все пути — через `PhoenixKitManufacturing.Paths` (`lib/phoenix_kit_manufacturing/paths.ex`), никаких хардкодов `/admin/manufacturing`.
- Все ошибки — через `PhoenixKitManufacturing.Errors.message/1`, новые атомы добавляются туда же.
- Контекстные функции: `opts \\ []`, `actor_uuid:` → activity log через существующие приватные хелперы `log_activity/5`/`maybe_log_activity/5` в `machines.ex` (новые контексты — по этому же образцу, каждый в своём модуле с собственными приватными копиями хелперов, т.к. между standalone-контекстами нет общего mixin).
- Любое чтение из мягкой (soft) UUID-связи (Location/Space) — `rescue`, никогда не поднимает 500.
- `mix precommit` эквивалент на каждом шаге минимум: `mix compile --warnings-as-errors` в `/www/phoenix_kit_manufacturing`. Полный `mix format`/`mix credo --strict` — see финальная задача.
- Тесты пишутся для каждой задачи (unit — `ExUnit.Case, async: true`; DB-зависимые — `PhoenixKitManufacturing.DataCase, async: true`, тег `:integration`), но **test-БД недоступна в этой среде** — тесты не запускаем, только `mix compile --warnings-as-errors` как минимальная проверка + ревью кода. Живая проверка — только оркестратором на живом хосте (см. финальная задача).
- gettext (`priv/gettext/{en,et,ru}/LC_MESSAGES/default.po`) — extract/merge одним проходом в конце волны (задача перед финалом), не после каждой задачи — избежать повторного fuzzy-аудита (память `reference_gettext_fuzzy_merge.md`).

---

## Группа A. Инфраструктура миграций (пререквизит)

### М1. Исправить `migrated_version_runtime/1` на пошаговый probe ДО первого бампа версии

**Файлы:** `lib/phoenix_kit_manufacturing/migrations/machines.ex`; новый `test/phoenix_kit_manufacturing/migrations/machines_test.exs`.

**Что сделать:**
- Заменить текущую логику `migrated_version_runtime/1` (строки 39-55) на список проб `version_probes/0` вида `[{1, &probe_v1?/1}]` (пока только V1 — будущие задачи добавят `{2, ...}`, `{3, ...}`, `{4, ...}` сюда же).
- Добавить приватные хелперы:
  - `table_exists?(prefix, table)` — обобщение текущего `to_regclass`-запроса (принимает имя таблицы параметром).
  - `column_exists?(prefix, table, column)` — запрос к `information_schema.columns` (`table_schema = $1 AND table_name = $2 AND column_name = $3`).
- `migrated_version_runtime/1` = `version_probes()` отсортировать по убыванию версии, вернуть версию первой пробы, которая прошла (`probe.(prefix) == true`), иначе `0`. Обернуть в тот же `rescue -> 0`, что и сейчас.
- `probe_v1?/1` = `table_exists?(prefix, "phoenix_kit_machines")` — сохраняет текущее поведение для V1, но теперь это явный, расширяемый список, а не «table exists ⇒ current_version».
- Добавить тест (integration, `:integration` тег) на `migrated_version_runtime/1`: без таблицы → 0; после `up(prefix: "public")` → 1 (соответствует `current_version()` на момент этой задачи).

**Проверка:** `cd /www/phoenix_kit_manufacturing && mix compile --warnings-as-errors`. Без DB тест не запускается — фиксируем как написанный, не выполненный.

---

## Группа B. Паспорт станка + мягкая привязка к месту (wave §В.1)

### М2. Добавить mix-зависимость `phoenix_kit_locations`

**Файлы:** `mix.exs`.

**Что сделать:** в `defp deps do` добавить `pk_dep(:phoenix_kit_locations, "~> 0.2")` (сразу после `pk_dep(:phoenix_kit, ...)`, по образцу `phoenix_kit_warehouse/mix.exs:92-95`); добавить `:phoenix_kit_locations` в `application/0` → `extra_applications`; дополнить `dialyzer: [plt_add_apps: [...]]` (сейчас `[:phoenix_kit]`) значением `:phoenix_kit_locations`.

**Проверка:** `cd /www/phoenix_kit_manufacturing && (PHOENIX_KIT_LOCATIONS_PATH=../phoenix_kit_locations mix deps.get)` (если Hex-версия ещё не содержит PlacePicker/`Spaces.full_path/2` — использовать локальный path-override для разработки модуля; см. находку №3), затем `mix compile --warnings-as-errors`. Контрольная точка оркестратора: подтвердить, что `phoenix_kit_locations` резолвится и в `<host-app>` (там уже path-override, см. `mix.exs:83`) без конфликтов версий.

### М3. Миграция V2 — паспорт станка + `field_template` на типе

**Файлы:** `lib/phoenix_kit_manufacturing/migrations/machines.ex`.

**Что сделать:**
- `@current_version 2`.
- В `version_probes/0` (из М1) добавить `{2, &probe_v2?/1}`, где `probe_v2?/1 = column_exists?(prefix, "phoenix_kit_machines", "manufacture_year")`.
- `up/1`: добавить блок отдельных `execute/1` (каждый `ADD COLUMN IF NOT EXISTS` — свой `execute/1`, как уже сделано с отдельными `CREATE TABLE`/`CREATE INDEX` в V1):
  `ALTER TABLE #{p}phoenix_kit_machines ADD COLUMN IF NOT EXISTS model VARCHAR(255)`, аналогично `manufacture_year INTEGER`, `commissioned_on DATE`, `warranty_until DATE`, `to_last_on DATE`, `to_interval_days INTEGER`, `to_next_on DATE`, `notes TEXT`, `location_uuid UUID`, `space_uuid UUID` — плюс `CREATE INDEX IF NOT EXISTS idx_machines_location ON #{p}phoenix_kit_machines (location_uuid)`.
  И `ALTER TABLE #{p}phoenix_kit_machine_types ADD COLUMN IF NOT EXISTS field_template JSONB NOT NULL DEFAULT '[]'`.
- `down/1`: симметричные `DROP COLUMN IF EXISTS` (в обратном порядке; `location_uuid`-индекс дропнуть первым).
- `@disable_ddl_transaction true` на модуле `PhoenixKitManufacturing.Migrations.Machines` (см. находку №2 — форвард-совместимо, документирует намерение, но не даёт защиты через текущий codegen `phoenix_kit.update`).
- Обновить `@moduledoc`: список таблиц/версий.

**Проверка:** `mix compile --warnings-as-errors`. **Контрольная точка оркестратора** (после того как М1-М9 скомпилированы): `mix phoenix_kit.update` в `<host-app>`, затем через Tidewave (`execute_sql_query`) убедиться, что реально появились все 10 новых колонок и `field_template` (см. находку №1 и №2 — если PgBouncer тихо съел DDL, чинить по рецепту `reference_pgbouncer_migrations.md`).

### М4. `Schemas.Machine` — новые поля, статусы `repair`/`mothballed`

**Файлы:** `lib/phoenix_kit_manufacturing/schemas/machine.ex`.

**Что сделать:**
- `@statuses ~w(active maintenance repair mothballed decommissioned)`.
- Новые поля в `schema/1`: `field(:model, :string)`, `field(:manufacture_year, :integer)`, `field(:commissioned_on, :date)`, `field(:warranty_until, :date)`, `field(:to_last_on, :date)`, `field(:to_interval_days, :integer)`, `field(:to_next_on, :date)`, `field(:notes, :string)`, `field(:location_uuid, :binary_id)`, `field(:space_uuid, :binary_id)` — без `belongs_to`/FK (мягкая ссылка, см. §Б.1).
- `@optional_fields` пополнить всеми новыми полями.
- `changeset/2`: `validate_number(:to_interval_days, greater_than: 0)` (только если задано), `validate_length(:model, max: 255)`, `validate_length(:notes, max: 2000)`.
- Приватная `maybe_compute_next_maintenance/1`: если `to_last_on` и `to_interval_days` присутствуют (через `get_field/2`) и `to_next_on` НЕ было явно передано в `attrs` (через `get_change/2` пусто), проставить `to_next_on = Date.add(to_last_on, to_interval_days)`. Вызывается последним шагом пайплайна `changeset/2`.
- `statuses/0` возвращает обновлённый список.

**Проверка:** `mix compile --warnings-as-errors`; добавить/обновить unit-тесты в `test/phoenix_kit_manufacturing/schemas/machine_test.exs` (валидность новых статусов, авто-расчёт `to_next_on`, границы `to_interval_days`).

### М5. `Schemas.MachineType` — поле `field_template`

**Файлы:** `lib/phoenix_kit_manufacturing/schemas/machine_type.ex`.

**Что сделать:**
- `field(:field_template, {:array, :map}, default: [])`.
- `@optional_fields` += `:field_template`.
- `changeset/2` → `validate_field_template/1` (приватная): для каждого элемента списка — `key` (непустая строка), `label` (непустая строка), `type in ~w(text number date boolean select)`, `unit` (опц. строка), `required` (опц. boolean), `options` (опц. список строк, **обязателен**, если `type == "select"` — см. находку №5). Дубликаты `key` в пределах одного шаблона — ошибка `add_error(:field_template, "duplicate key: ...")`. Невалидная форма строки целиком — `add_error(:field_template, "invalid row at index N")`.

**Проверка:** `mix compile --warnings-as-errors`; расширить `test/phoenix_kit_manufacturing/schemas/machine_type_test.exs` (валидный шаблон; `select` без `options` → ошибка; дубликат `key` → ошибка; неизвестный `type` → ошибка).

### М6. `Machines` — хелперы `location_label/1` и `merged_field_template/1`

**Файлы:** `lib/phoenix_kit_manufacturing/machines.ex`.

**Что сделать:**
- `location_label(%Machine{} = machine, opts \\ [])`: если `space_uuid` задан → `PhoenixKitLocations.Spaces.full_path(machine.space_uuid, locale: opts[:locale])`, `rescue -> nil`; если результат `nil`/пусто и задан `location_uuid` → `PhoenixKitLocations.Locations.get_location(machine.location_uuid)` → имя (с учётом `locale` через `PhoenixKit.Utils.Multilang`, по образцу `place_picker.ex:232-237`), `rescue -> nil`; если и это `nil`, и задан `location_note` (legacy) → вернуть его; иначе `nil`. Оборачивать оба cross-module вызова в `rescue` (мягкая связь, БД `phoenix_kit_locations` может быть недоступна).
- `merged_field_template(type_uuids)` (принимает список uuid типов, уже отфильтрованный по «выбрано в форме»): подтягивает `MachineType` записи через `list_machine_types(status: "active")`, фильтрует до `type_uuids`, сохраняя порядок списка `list_machine_types/1` (asc по `name` — детерминированно), затем `Enum.reduce` по их `field_template`, добавляя строки в аккумулятор-список **только если такого `key` там ещё нет** («первый выигрывает» — порядок = алфавитный порядок имени типа).

**Проверка:** `mix compile --warnings-as-errors`; unit/integration тесты в `test/phoenix_kit_manufacturing/machines_test.exs` на `merged_field_template/1` (конфликт ключей → первый по алфавиту типа побеждает) и `location_label/1` (все ветки, включая отсутствие phoenix_kit_locations данных — замокать через `rescue`-путь, т.е. вызывать с заведомо несуществующим uuid).

### М7. `MachineFormLive` — паспорт, PlacePicker, динамические поля `metadata`

**Файлы:** `lib/phoenix_kit_manufacturing/web/machine_form_live.ex`.

**Что сделать:**
- `@statuses ~w(active maintenance repair mothballed decommissioned)`; `status_label/1` пополнить `"repair"`/`"mothballed"`.
- Новые поля формы (grid `sm:grid-cols-2`, как уже сделано для `code`/`manufacturer`): `model`, `manufacture_year` (`type="number"`), `commissioned_on`/`warranty_until`/`to_last_on`/`to_next_on` (`type="date"`), `to_interval_days` (`type="number"`), `notes` (`<.textarea>`).
- `location_note`: показывать `<.input field={@form[:location_note]}>` только когда `@machine.location_note` не пусто (legacy-текст, см. §Б/задание) — условие `:if={@action == :edit and @machine.location_note not in [nil, ""]}`; для `:new` не рендерить вообще.
- Секция «Место»: read-only summary `Machines.location_label(@machine, locale: ...)` (или «Не задано»), кнопка «Изменить» переключающая `@show_place_picker` (по умолчанию `true`, если `location_uuid`/`space_uuid` оба `nil`, иначе `false`). Внутри — `<.live_component module={PhoenixKitLocations.Web.Components.PlacePicker} id="machine-place-picker" selected_space_uuid={@space_uuid} locale={@current_locale}/>`, показывается только когда `@show_place_picker`.
- `mount/3`/`handle_params`: assign `:location_uuid`, `:space_uuid` из `machine.location_uuid`/`machine.space_uuid` (для `:new` — `nil`).
- `handle_info({:place_picker_select, "machine-place-picker", %{location_uuid: uuid, space_uuid: space_uuid}}, socket)`: обновить `@location_uuid`/`@space_uuid`, закрыть пикер (`@show_place_picker = false`) — добавить ДО существующего catch-all `handle_info/2` (строки 116-119), т.к. Elixir матчит клозы по порядку.
- Динамические поля `metadata`: `assigns.merged_template = Machines.merged_field_template(MapSet.to_list(@linked_type_uuids))`, пересчитывать после `toggle_type` (аналогично текущему обновлению `linked_type_uuids`). Рендер — цикл по `@merged_template`, для каждого `%{key:, label:, type:, unit:, required:, options:}`:
  - `text`/`select-без-options`(fallback) → `<.input type="text">`;
  - `number` → `<.input type="number">`;
  - `date` → `<.input type="date">`;
  - `boolean` → `<.checkbox>` (core-компонент, см. CLAUDE.md «Core Form Components»);
  - `select` (с `options`) → `<.select options={...}>`.
  Имя поля — `machine[metadata][KEY]`, значение по умолчанию — `Map.get(@machine.metadata, key, "")`. `unit`/`required` — вспомогательная подпись рядом с `label`.
- `save_machine/3`: перед вызовом `Machines.create_machine/update_machine` — смёржить в `params`: `"location_uuid" => @location_uuid, "space_uuid" => @space_uuid`; `metadata` — коэрсировать boolean-поля шаблона (`"true"/"on"` → `true`, отсутствие чекбокса → `false`), остальные типы оставить строками «как есть» (см. находку №6), затем `Map.put(params, "metadata", coerced)`.

**Проверка:** `mix compile --warnings-as-errors`. Контрольная точка оркестратора (после М8, М13, М19, М27 — полный цикл формы): создать станок, выбрать тип с `field_template`, задать место через PlacePicker, сохранить, открыть на редактирование — проверить, что summary места и значения metadata отобразились.

### М8. `MachinesLive` (`:index`) — статусы + колонка «Место»

**Файлы:** `lib/phoenix_kit_manufacturing/web/machines_live.ex`.

**Что сделать:** `status_label/1`/`status_badge_class/1` — добавить `"repair"` (`badge-warning` или отдельный оттенок, не совпадающий с `maintenance`) и `"mothballed"` (`badge-ghost badge-outline`). Добавить столбец «Место» в `machines_table/1` (и в `card_fields`) через `Machines.location_label(m, locale: ...)`. *(Примечание: этот файл будет переписан в задаче М17 под ColumnConfig — здесь минимальные точечные правки, чтобы `:index` не сломался между задачами; М17 заберёт «Место» в состав колонок.)*

**Проверка:** `mix compile --warnings-as-errors`.

---

## Группа C. Динамический редактор `field_template` на форме типа станка

### М9. `MachineTypeFormLive` — редактор строк `field_template`

**Файлы:** `lib/phoenix_kit_manufacturing/web/machine_type_form_live.ex`.

**Что сделать:**
- Socket assign `:field_template_rows` (список map, инициализируется из `machine_type.field_template`, для `:new` — `[]`).
- `handle_event("add_field_row", _params, socket)` — добавить пустую строку `%{"key" => "", "label" => "", "type" => "text", "unit" => "", "required" => false, "options" => []}`.
- `handle_event("remove_field_row", %{"index" => idx}, socket)` — удалить по индексу.
- В `handle_event("validate"/"save", ...)`: собрать `params["field_template"]` (приходит как map с числовыми строковыми ключами `%{"0" => %{...}, "1" => %{...}}` — стандартное HTML-кодирование индексированных полей) → `Enum.sort_by` по числовому ключу → список map → **до** передачи в `merge_translatable_params/4` подмешать в `params` под ключом `"field_template"` (не входит в `@translatable_fields`, проходит как обычное non-translatable поле — см. правило «wrapper scope» в CLAUDE.md phoenix_kit).
- Разметка: каждая строка — `key`/`label` (`<.input>`), `type` (`<.select>` из `~w(text number date boolean select)`), `unit` (`<.input>`), `required` (`<.checkbox>`), и — только когда `type == "select"` для этой строки — доп. `<.input>` «Options (через запятую)», парсится в список строк на save. Кнопка «+ Добавить поле» / иконка-крестик на каждой строке (`phx-click="remove_field_row" phx-value-index={i}`), по образцу toggle-бейджей типов в `machine_form_live.ex:254-274`, но как список, а не набор бейджей.

**Проверка:** `mix compile --warnings-as-errors`.

---

## Группа D. Файлы/фото (Attachments-паттерн)

### М10. Новый модуль `PhoenixKitManufacturing.Attachments`

**Файлы:** новый `lib/phoenix_kit_manufacturing/attachments.ex` (адаптация `/www/phoenix_kit_locations/lib/phoenix_kit_locations/attachments.ex`, 1:1 копия механики, только:

**Что сделать:**
- `alias PhoenixKitManufacturing.Schemas.Machine` вместо `Location`/`Space`.
- `folder_name_for(%Machine{uuid: uuid}) when is_binary(uuid), do: {:ok, "machine-#{uuid}"}`; `folder_name_for(_), do: :pending`.
- Единственный используемый scope — константа `"machine"` (в отличие от locations, здесь не нужен multi-scope map per floor/room — но сама реализация всё равно работает через `attachments_by_scope`, ничего не упрощаем в самой механике, чтобы не расходиться с прецедентом и оставить задел на будущее multi-resource использование, напр. Operations).
- Все остальные функции (`init/1`, `mount/2`, `allow_attachment_upload/1`, `open_featured_image_picker/2`, `trash_file/3`, `handle_progress/3`, `inject_attachment_data/3`, `maybe_rename_pending_folder_for/2`, форматтеры) — переносятся без изменений логики, только module-doc актуализировать под Machine.

**Проверка:** `mix compile --warnings-as-errors`.

### М11. Новый компонент `PhoenixKitManufacturing.Web.Components.FilesCard`

**Файлы:** новый `lib/phoenix_kit_manufacturing/web/components/files_card.ex` (копия `/www/phoenix_kit_locations/lib/phoenix_kit_locations/web/components/files_card.ex`, только `alias PhoenixKitManufacturing.Attachments` вместо `PhoenixKitLocations.Attachments`, DOM id `pk-manufacturing-dropzone-#{@scope}`, JS-хук `.PkManufacturingUploadScope`). `URLSigner`/`Icon`/gettext backend — как в оригинале (`PhoenixKit.Modules.Storage.URLSigner` — core, доступен без доп. зависимостей).

**Проверка:** `mix compile --warnings-as-errors`.

### М12. `MachineFormLive` — секция «Файлы» + `MediaSelectorModal`

**Файлы:** `lib/phoenix_kit_manufacturing/web/machine_form_live.ex`.

**Что сделать:**
- `mount/3`: `|> Attachments.init() |> Attachments.allow_attachment_upload() |> Attachments.mount(scope: "machine", resource: machine)`.
- Рендер: `<.live_component module={PhoenixKitWeb.Live.Components.MediaSelectorModal} id="machine-form-media-selector" show={@show_media_selector} mode={@media_selection_mode} file_type_filter={@media_filter} selected_uuids={@media_selected_uuids} scope_folder_id={Attachments.state(%{assigns: assigns}, "machine").folder_uuid} phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}/>` (в начале шаблона, по образцу `location_form_live.ex:306-315`), плюс `<.files_card_body scope="machine" state={Attachments.state(@socket, "machine")} uploads={@uploads}/>` как новый блок-`<div class="divider">…</div>` в карточке формы, между блоком «Machine Types» и кнопками submit (не multi-tab, см. находку №8).
- `handle_event`: `"open_featured_image_picker"`, `"close_media_selector"`, `"cancel_upload"`, `"remove_file"`, `"clear_featured_image"`, `"set_active_upload_scope"` — делегируют в соответствующие `Attachments.*` функции (1:1 как `location_form_live.ex:212-230`), scope везде — литерал `"machine"` (не берётся из `phx-value-scope`, т.к. на этой форме только один scope).
- `handle_info({:media_selected, file_uuids}, socket)` → `Attachments.handle_media_selected(socket, file_uuids)`; `handle_info({:media_selector_closed}, socket)` → закрыть модалку — оба клозы ДО catch-all.
- `save_machine/3`: `params |> Attachments.inject_attachment_data(socket, "machine")` перед вызовом контекста; после успешного `create_machine` (только `:new`) — `Attachments.maybe_rename_pending_folder_for(Attachments.state(socket, "machine").folder_uuid, machine)`.

**Проверка:** `mix compile --warnings-as-errors`.

### М13. Миниатюра фото в списке/карточке станков

**Файлы:** `lib/phoenix_kit_manufacturing/web/machines_live.ex` (или уже переписанный `MachinesLive` из М17, если задачи выполняются в этом порядке — тогда правки вносятся туда).

**Что сделать:** для каждого станка подтянуть `featured_image_uuid` из `machine.data["featured_image_uuid"]`, если задан — резолвить файл через `PhoenixKit.Modules.Storage.get_file/1` (`rescue -> nil`) и показать `<img src={URLSigner.signed_url(uuid, "thumbnail")}>` (24-32px) слева от имени станка в первой колонке таблицы и в `card_header` мобильной карточки; при отсутствии — иконка-заглушка `hero-camera` в кружке `bg-base-200`.

**Проверка:** `mix compile --warnings-as-errors`.

---

## Группа E. Обвязка списка станков (ColumnConfig/ColumnManagement/ViewConfigs) + Comments

### М14. `PhoenixKitManufacturing.ViewConfigs`

**Файлы:** новый `lib/phoenix_kit_manufacturing/view_configs.ex` (копия `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/view_configs.ex`, `setting_key/2` → `"manufacturing_view_config:#{scope}:#{user_uuid}"`, module-doc актуализировать).

**Проверка:** `mix compile --warnings-as-errors`.

### М15. `PhoenixKitManufacturing.ColumnConfig` (движок) + `ColumnConfig.Machines`

**Файлы:** новый `lib/phoenix_kit_manufacturing/column_config.ex` (копия `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/column_config.ex`, `Gettext` backend → `PhoenixKitManufacturing.Gettext`, `defmacro __using__` без изменений механики); новый `lib/phoenix_kit_manufacturing/column_config/machines.ex` (по образцу `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/column_config/inventories.ex`).

**Что сделать в `ColumnConfig.Machines`** (`use PhoenixKitManufacturing.ColumnConfig, scope: "manufacturing_machines"`), колонки (`columns/0`):
- `name` (default, sortable, filterable text);
- `code` (default, sortable, filterable text);
- `types` (default, не sortable — список бейджей; filterable `:enum` по `distinct_options(entries, :types_csv)` или аналог);
- `status` (default, sortable, filterable `:enum`, опции = `Machine.statuses/0` + `status_label/1`);
- `location` (default, sortable по строке, filterable text);
- `manufacturer` (не default, sortable, filterable text);
- `model` (не default, sortable, filterable text);
- `manufacture_year` (не default, sortable, filterable `:numeric_range`);
- `commissioned_on` (не default, sortable, filterable `:date_range`);
- `warranty_until` (не default, sortable, filterable `:date_range`);
- `to_next_on` (не default, sortable, filterable `:date_range` — полезно для «скоро ТО»).

Записи станков для колонок обогащаются (`enrich_machines/1` в LiveView, задача М17) до плоских map — как `enrich_documents/1` в `inventories_live.ex:133-146`.

**Проверка:** `mix compile --warnings-as-errors`.

### М16. `Web.ColumnManagement` (макрос) + `Web.Components.ColumnModal`

**Файлы:** новый `lib/phoenix_kit_manufacturing/web/column_management.ex` (копия `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/column_management.ex`, замена модуля-namespace на `PhoenixKitManufacturing`, механика без изменений); новый `lib/phoenix_kit_manufacturing/web/components/column_modal.ex` (копия `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/components/column_modal.ex`, `Gettext`/`DraggableList` — `DraggableList` берётся из core `PhoenixKitWeb.Components.Core.DraggableList`, доп. зависимости не нужны).

**Проверка:** `mix compile --warnings-as-errors`.

### М17. Переписать `:index` в `MachinesLive` на ColumnConfig/ColumnManagement/ColumnModal

**Файлы:** `lib/phoenix_kit_manufacturing/web/machines_live.ex`.

**Что сделать:**
- `use PhoenixKitManufacturing.Web.ColumnManagement, column_config: PhoenixKitManufacturing.ColumnConfig.Machines, scope: "manufacturing_machines"`.
- `mount/3`: assign `:current_user_uuid` (из `phoenix_kit_current_scope`, по образцу `inventories_live.ex:44-47`), `:search`, `:sort_by`, `:sort_dir`.
- `handle_params/3` (только для `:index`-ветки; `:types` остаётся на старой простой загрузке из М8): `PhoenixKitManufacturing.Web.ColumnManagement.assign_column_state(ColumnConfig.Machines)` → `assign_machines/1` (search + `apply_column_filters/3` + `apply_sort/3`, по образцу `inventories_live.ex:122-131`).
- `__view_config_changed__/1` override — пересчитать `assign_machines/1`, сбросить `sort_by`, если колонка скрыта (как `inventories_live.ex:74-83`).
- Рендер `:index`-ветки — `table_default` с `toolbar_title` (поиск + упрощённый индикатор фильтров — **не копируем** `FilterChips` из warehouse в этой волне ради экономии объёма; вместо чипов — простая надпись «фильтры: N активно» и сброс одной кнопкой; если потребуется полный chip-UI, это отдельная последующая задача — отмечено в открытых вопросах), `toolbar_actions` (New Machine + сортировка + кнопка «Columns» → `show_column_modal`), `<ColumnModal.column_modal .../>` в конце.
- `:types` (и позже `:operations`/`:defect_reasons` из групп F/G) остаются на прежнем `types_table/1`-подобном рендере без ColumnConfig (см. находку №9).
- Сюда же — фото-миниатюра из М13 (колонка «name» рендерит `<img>`+ссылку вместо голого текста).

**Проверка:** `mix compile --warnings-as-errors`. Контрольная точка оркестратора: живой список станков — поиск, сортировка по всем колонкам, модалка выбора колонок (добавить/убрать/переупорядочить drag&drop), фильтр по статусу/дате ТО, сохранение вида (перезайти на страницу — настройки должны сохраниться через `manufacturing_view_config:manufacturing_machines:<user_uuid>` в `phoenix_kit_settings`).

### М18. Comments-обёртка

**Файлы:** `mix.exs`; новый `lib/phoenix_kit_manufacturing/comments.ex`; новый `lib/phoenix_kit_manufacturing/web/components/comments_panel.ex`; `lib/phoenix_kit_manufacturing/web/machine_form_live.ex`.

**Что сделать:**
- `mix.exs`: `pk_dep(:phoenix_kit_comments, "~> 0.2")` в `deps/0`, `:phoenix_kit_comments` в `extra_applications`.
- `Comments` — упрощённая копия `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/comments.ex`: `@resource_types %{machine: "machine"}`, `@compile {:no_warn_undefined, PhoenixKitComments}`, функции `resource_type/1`, `available?/0`, `count/2`, `counts/2`, `subscribe/2`, `unsubscribe/2` — сигнатуры оставляем параметризованными по `kind` (сейчас единственный ключ `:machine`) ради единообразия с прецедентом и задела на Operations/DefectReasons в будущем.
- `CommentsPanel.panel/1` — копия `comments_panel.ex`, `kind` атрибут сужен до `values: [:machine]`.
- В `MachineFormLive` (только `@action == :edit`, т.к. `:new` не имеет `uuid`): блок `<div class="divider">…</div>` + `<CommentsPanel.panel kind={:machine} resource_uuid={@machine.uuid} current_user={...} title={gettext("Comments")}/>`, показывается `:if={PhoenixKitManufacturing.Comments.available?() and @action == :edit}`.

**Проверка:** `mix compile --warnings-as-errors`. Контрольная точка оркестратора: открыть станок на редактирование — если `phoenix_kit_comments` включён в `<host-app>`, секция комментариев видна и работает (написать/лайкнуть комментарий, `resource_type = "machine"`).

---

## Группа F. Справочник Операций + M2M со станком (wave §В.5)

### М19. Миграция V3 — `phoenix_kit_operations` + `phoenix_kit_machine_operations`

**Файлы:** `lib/phoenix_kit_manufacturing/migrations/machines.ex`.

**Что сделать:**
- `@current_version 3`; `version_probes/0` += `{3, fn p -> table_exists?(p, "phoenix_kit_operations") end}`.
- `up/1` добавляет `CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_operations` (`uuid` PK, `name VARCHAR(255) NOT NULL`, `unit VARCHAR(50)`, `base_time_norm_seconds INTEGER`, `status VARCHAR(20) NOT NULL DEFAULT 'active'`, `data JSONB NOT NULL DEFAULT '{}'`, timestamps) + `CREATE INDEX IF NOT EXISTS idx_operations_status`; и `CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_machine_operations` (`uuid` PK, `machine_uuid UUID NOT NULL REFERENCES ... phoenix_kit_machines ON DELETE CASCADE`, `operation_uuid UUID NOT NULL REFERENCES ... phoenix_kit_operations ON DELETE CASCADE`, `time_norm_seconds INTEGER` nullable override, timestamps) + `CREATE UNIQUE INDEX IF NOT EXISTS idx_machine_operations_unique ON ... (machine_uuid, operation_uuid)` + `CREATE INDEX IF NOT EXISTS idx_machine_operations_operation ON ... (operation_uuid)`.
- `down/1`: `DROP TABLE IF EXISTS ... machine_operations CASCADE` затем `... operations CASCADE` (порядок как в V1 down для type_assignments/machines/types).

**Проверка:** `mix compile --warnings-as-errors`. Контрольная точка оркестратора вместе с М3 (или отдельным прогоном `mix phoenix_kit.update`).

### М20. Схемы `Operation` и `MachineOperation`

**Файлы:** новый `lib/phoenix_kit_manufacturing/schemas/operation.ex`; новый `lib/phoenix_kit_manufacturing/schemas/machine_operation.ex`.

**Что сделать:**
- `Operation` — по образцу `schemas/machine_type.ex`: `@primary_key {:uuid, UUIDv7, autogenerate: true}`, `@statuses ~w(active inactive)`, поля `name`, `unit`, `base_time_norm_seconds` (`:integer`), `status` (default `"active"`), `data` (`:map`, default `%{}`, мультиязычное `name` через `MultilangForm`), `has_many :machine_operations`, `has_many :machines, through: [:machine_operations, :machine]`. `changeset/2`: `required = [:name]`, `optional = [:unit, :base_time_norm_seconds, :status, :data]`, `validate_number(:base_time_norm_seconds, greater_than_or_equal_to: 0)` (если задано), `validate_inclusion(:status, @statuses)`.
- `MachineOperation` — по образцу `schemas/machine_type_assignment.ex`: `belongs_to :machine`/`belongs_to :operation` (FK `operation_uuid` → `PhoenixKitManufacturing.Schemas.Operation`), `field(:time_norm_seconds, :integer)` (nullable override), `changeset/2` — `cast [:machine_uuid, :operation_uuid, :time_norm_seconds, :inserted_at, :updated_at]`, `validate_required([:machine_uuid, :operation_uuid])`, `assoc_constraint(:machine)`, `assoc_constraint(:operation)`, `validate_number(:time_norm_seconds, greater_than_or_equal_to: 0)` если задано.

**Проверка:** `mix compile --warnings-as-errors`; unit-тесты `test/phoenix_kit_manufacturing/schemas/operation_test.exs` (+ `machine_operation_test.exs`), по образцу `machine_type_test.exs`.

### М21. Контекст `PhoenixKitManufacturing.Operations` (CRUD)

**Файлы:** новый `lib/phoenix_kit_manufacturing/operations.ex`.

**Что сделать:** по образцу секции «Machine Types» в `machines.ex:51-116`: `list_operations(opts \\ [])` (фильтр `:status`, order by `:name`), `get_operation/1`, `get_operation_by_name/1`, `count_operations/1`, `create_operation/2`, `update_operation/3`, `delete_operation/2` (hard-delete, каскадит на `machine_operations`), `change_operation/2`. Activity-log — свои приватные копии `log_activity/5`/`maybe_log_activity/5`/`changeset_error_metadata/1` (см. раздел 3), `@module_key "manufacturing"`, `resource_type "operation"`, действия `"operation.created"`/`"operation.updated"`/`"operation.deleted"`.

**Проверка:** `mix compile --warnings-as-errors`.

### М22. `Machines` — секция «Machine ↔ Operation linking»

**Файлы:** `lib/phoenix_kit_manufacturing/machines.ex`.

**Что сделать:** новая секция (по образцу «Machine ↔ Type linking», строки 209-303):
- `list_machine_operations(machine_uuid)` — возвращает список `%{operation: Operation.t(), time_norm_seconds: integer() | nil}` (join `MachineOperation` + preload `:operation`), `order_by: [asc: o.name]`.
- `linked_operation_overrides(machine_uuid)` — `%{operation_uuid => time_norm_seconds_or_nil}` map, для инициализации формы.
- `sync_machine_operations(machine_uuid, overrides_map, opts \\ [])` где `overrides_map :: %{operation_uuid => time_norm_seconds | nil}` — по образцу `sync_machine_types/3`: сравнение before/after set ключей **и** значений (не только набора uuid, т.к. override может измениться при том же наборе операций — если set ключей одинаков, но значения отличаются, тоже считать `:synced`, не `:unchanged`), транзакция `delete_all` + `insert!` по каждому ключу, лог `"machine.operations_synced"`.
- `has_operation?(machine_uuid, operation_uuid)` — по образцу `has_type?/2`.

**Проверка:** `mix compile --warnings-as-errors`; тесты в `machines_test.exs` (sync добавляет/убирает/меняет override, `:unchanged` при точном повторе).

### М23. `OperationFormLive`

**Файлы:** новый `lib/phoenix_kit_manufacturing/web/operation_form_live.ex` (копия структуры `machine_type_form_live.ex`).

**Что сделать:** `@translatable_fields ["name"]` (§Б.3 не упоминает отдельного `description` у операции — только `name` мультиязычно через `data`; `unit`/`base_time_norm_seconds`/`status` — обычные core-инпуты вне `data`). `@preserve_fields %{"unit" => :unit, "base_time_norm_seconds" => :base_time_norm_seconds, "status" => :status}`. Остальное — 1:1 структура `machine_type_form_live.ex` (mount/load/save/render с `multilang_tabs`/`multilang_fields_wrapper`/`translatable_field`).

**Проверка:** `mix compile --warnings-as-errors`.

### М24. `MachinesLive` — подтаб `:operations`

**Файлы:** `lib/phoenix_kit_manufacturing/web/machines_live.ex`.

**Что сделать:** третья ветка `live_action` — `:operations`: `tab_title(:operations)`, `load_data(socket, :operations)` → `assign(:operations, Operations.list_operations())`, `operations_table/1` компонент (по образцу `types_table/1`: колонки Name/Unit/Base norm (форматировать секунды в `HH:MM:SS` или «N с» — простая функция `format_duration/1`)/Status/Actions), delete-confirm через существующий `confirm_delete` механизм — добавить кейсы `"operation"` в `handle_event("show_delete_confirm", ...)`-обвязку (`fetch_for_delete/2`, `delete_for_kind/2`, `deleted_message/1`, `not_found_atom/1`, `delete_failed_atom/1`, `reload_action/1` — каждый получает клоз `:operation`), новую `.confirm_modal` для операций, кнопку «New Operation» в `<:actions>` при `@active_tab == :operations`.

**Проверка:** `mix compile --warnings-as-errors`.

### М25. `admin_tabs/0` — табы Operations

**Файлы:** `lib/phoenix_kit_manufacturing.ex`.

**Что сделать:** по образцу `:manufacturing_types`/`:manufacturing_type_new`/`:manufacturing_type_edit` (без `match:` override — default-поведение `Tab` уже корректно исключает пересечение с `:manufacturing_machines`, т.к. у той регексом жёстко заякорено `$` на `machines`/`machines/new`/`machines/:x/edit`, и путь Operations содержит дополнительный сегмент `/operations`, под этот шаблон не попадающий):
- `%Tab{id: :manufacturing_operations, label: "Operations", icon: "hero-clock", path: "manufacturing/machines/operations", priority: 158, parent: :manufacturing, live_view: {PhoenixKitManufacturing.Web.MachinesLive, :operations}}` — приоритеты 158+ смещают текущие `machine_new(158)/type_new(159)/type_edit(160)/machine_edit(161)` на следующие свободные номера; пересчитать все приоритеты последовательно, сохраняя порядок «Types(157) → Operations(158) → скрытые New/Edit-табы → wildcard `:uuid`-табы последними».
- `%Tab{id: :manufacturing_operation_new, path: "manufacturing/machines/operations/new", visible: false, live_view: {PhoenixKitManufacturing.Web.OperationFormLive, :new}}`.
- `%Tab{id: :manufacturing_operation_edit, path: "manufacturing/machines/operations/:uuid/edit", visible: false, live_view: {PhoenixKitManufacturing.Web.OperationFormLive, :edit}}` — **после** остальных статичных путей, среди других wildcard `:uuid` табов (тот же принцип, что уже соблюдён для `machine_edit`/`type_edit`).

**Проверка:** `mix compile --warnings-as-errors`. Контрольная точка оркестратора: рестарт хоста (path-dep, авто-discovery роутов при старте — см. память про рестарты), проверить `HostWeb.Router.__routes__()` (или открыть `/admin/manufacturing/machines/operations` и `.../operations/new` в браузере) — новые роуты появились.

### М26. `Paths` — хелперы Operations

**Файлы:** `lib/phoenix_kit_manufacturing/paths.ex`.

**Что сделать:** `operations/0`, `operation_new/0`, `operation_edit/1` — по образцу `types/0`/`type_new/0`/`type_edit/1`. Обновить все ссылки в М24/М25/М27 на эти хелперы вместо строковых путей.

**Проверка:** `mix compile --warnings-as-errors`.

### М27. `MachineFormLive` — секция «Операции» в карточке станка

**Файлы:** `lib/phoenix_kit_manufacturing/web/machine_form_live.ex`.

**Что сделать:** новый блок `<div class="divider">…</div>` (порядок секций в форме: Types → Operations → Files → Comments): список всех активных `Operations.list_operations(status: "active")`, каждая строка — чекбокс «включена для этого станка» (toggle, аналог `toggle_type`) + при включении — необязательный `<.input type="number">` «Override normy (сек), пусто = базовая» с текущим значением из `@operation_overrides` (map в assigns, инициализируется из `Machines.linked_operation_overrides(machine.uuid)` на `:edit`). `handle_event("toggle_operation", %{"uuid" => uuid}, socket)` и `handle_event("set_operation_override", %{"uuid" => uuid, "value" => value}, socket)`. На save — `sync_operations_and_redirect/3`-функция, вызывающая `Machines.sync_machine_operations/3` после `sync_machine_types`/типового пайплайна.

**Проверка:** `mix compile --warnings-as-errors`. Контрольная точка оркестратора: создать операцию, привязать к станку с override нормы, сохранить, перезайти — override отображается.

---

## Группа G. Справочник Причин брака (wave §В.6)

### М28. Миграция V4 — `phoenix_kit_defect_reasons`

**Файлы:** `lib/phoenix_kit_manufacturing/migrations/machines.ex`.

**Что сделать:** `@current_version 4`; `version_probes/0` += `{4, fn p -> table_exists?(p, "phoenix_kit_defect_reasons") end}`. `up/1`: `CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_defect_reasons` (`uuid` PK, `name VARCHAR(255) NOT NULL`, `description TEXT`, `status VARCHAR(20) NOT NULL DEFAULT 'active'`, `data JSONB NOT NULL DEFAULT '{}'`, timestamps) + `CREATE INDEX IF NOT EXISTS idx_defect_reasons_status`. `down/1`: `DROP TABLE IF EXISTS ... defect_reasons CASCADE`.

**Проверка:** `mix compile --warnings-as-errors`.

### М29. Схема `DefectReason`

**Файлы:** новый `lib/phoenix_kit_manufacturing/schemas/defect_reason.ex` (1:1 копия структуры `schemas/machine_type.ex`, без M2M-ассоциаций — в этой волне брак не привязывается к станку/этапу, см. §Б.4 — только справочник).

**Проверка:** `mix compile --warnings-as-errors`; тест `test/phoenix_kit_manufacturing/schemas/defect_reason_test.exs` по образцу `machine_type_test.exs`.

### М30. Контекст `PhoenixKitManufacturing.DefectReasons` (CRUD)

**Файлы:** новый `lib/phoenix_kit_manufacturing/defect_reasons.ex` (копия структуры секции Machine Types из `machines.ex:51-116`: `list_defect_reasons/1`, `get_defect_reason/1`, `count_defect_reasons/1`, `create_defect_reason/2`, `update_defect_reason/3`, `delete_defect_reason/2`, `change_defect_reason/2`, свои activity-log хелперы, `resource_type "defect_reason"`).

**Проверка:** `mix compile --warnings-as-errors`.

### М31. `DefectReasonFormLive`

**Файлы:** новый `lib/phoenix_kit_manufacturing/web/defect_reason_form_live.ex` (1:1 копия `machine_type_form_live.ex`, `@translatable_fields ["name", "description"]`, без `@preserve_fields` кроме `status`).

**Проверка:** `mix compile --warnings-as-errors`.

### М32. `MachinesLive` — подтаб `:defect_reasons`; `Paths` — хелперы

**Файлы:** `lib/phoenix_kit_manufacturing/web/machines_live.ex`; `lib/phoenix_kit_manufacturing/paths.ex`.

**Что сделать:** четвёртая ветка `live_action :defect_reasons` (симметрично М24: `defect_reasons_table/1`, delete-confirm кейс `"defect_reason"`, кнопка «New Defect Reason»). `Paths.defect_reasons/0`/`defect_reason_new/0`/`defect_reason_edit/1`.

**Проверка:** `mix compile --warnings-as-errors`.

### М33. `admin_tabs/0` — табы Defect Reasons

**Файлы:** `lib/phoenix_kit_manufacturing.ex`.

**Что сделать:** `%Tab{id: :manufacturing_defect_reasons, label: "Defect Reasons", icon: "hero-exclamation-triangle", path: "manufacturing/machines/defect-reasons", parent: :manufacturing, live_view: {PhoenixKitManufacturing.Web.MachinesLive, :defect_reasons}}` + скрытые `:manufacturing_defect_reason_new`/`:manufacturing_defect_reason_edit` (`path: ".../defect-reasons/new"` / `".../defect-reasons/:uuid/edit"`) — приоритеты продолжают последовательность из М25 (следующие свободные номера), путь через дефис `defect-reasons` (URL-конвенция модуля — дефисы/слэши, не underscore, см. раздел «Key conventions» в CLAUDE.md).

**Проверка:** `mix compile --warnings-as-errors`. Контрольная точка оркестратора: рестарт хоста, проверить новые роуты и nav-пункты (Machines / Types / Operations / Defect Reasons под родительским табом Manufacturing).

---

## Группа H. Финал волны

### М34. gettext extract/merge + аудит

**Файлы:** `priv/gettext/default.pot`, `priv/gettext/{en,et,ru}/LC_MESSAGES/default.po`.

**Что сделать:** `cd /www/phoenix_kit_manufacturing && mix gettext.extract && mix gettext.merge priv/gettext`. **Аудит всех трёх локалей включая `en`** через рендер реальных строк (не полагаться на fuzzy-мэтчинг — память `reference_gettext_fuzzy_merge.md`): выборочно пройтись по новым строкам (статусы `repair`/`mothballed`, паспорт-поля, Files/Comments/Operations/Defect Reasons UI) и убедиться, что fuzzy-merge не подставил семантически неверный перевод из похожей по форме существующей строки.

**Проверка:** `git diff --stat priv/gettext` — визуально пробежаться по diff на предмет подозрительных fuzzy-совпадений; `mix compile --warnings-as-errors`.

### М35. Финальный прогон качества + живая проверка оркестратором

**Файлы:** весь модуль.

**Что сделать:**
- `cd /www/phoenix_kit_manufacturing && mix format && mix credo --strict && mix compile --force --warnings-as-errors`.
- **Контрольная точка оркестратора** (живой хост):
  1. `mix phoenix_kit.update` в `<host-app>` (или локальный override пути, если ещё не опубликован Hex-пакет с обновлениями — см. память «Path-dep changes need restart» и «PhoenixKit migrations»). Прогнать один раз до V4 (или по шагам V1→V2→V3→V4, если оркестратор предпочитает контролировать каждый шаг отдельно — этапы М3/М19/М28 это допускают, т.к. каждый бамп независим).
  2. Через Tidewave (`execute_sql_query`/`project_eval`) свериться, что реально создались/изменились все таблицы и колонки на каждом шаге (см. находки №1-№2 — не доверять только выводу `mix phoenix_kit.update` о «успехе», проверять сам DDL из-за риска PgBouncer).
  3. `sudo /usr/bin/supervisorctl restart elixir` (обязателен из-за path-dep изменений в `phoenix_kit_manufacturing`/`phoenix_kit_locations`/`phoenix_kit_comments` — не хот-релоадится).
  4. Живой клик-тест: Machines index (поиск/сортировка/фильтры/колонки/фото), New/Edit Machine (паспорт, статусы `repair`/`mothballed`, PlacePicker выбор и последующее редактирование с сохранённым выбором, динамические поля из `field_template`, Files upload + featured image, Comments), Types (создание типа с `field_template`, включая `select` с `options`), Operations (CRUD + привязка к станку с override нормы), Defect Reasons (CRUD).
  5. Проверить `HostWeb.Router.__routes__()` на отсутствие дублей/коллизий путей после добавления Operations/Defect Reasons табов.

**Проверка:** пункты выше — все зелёные, `mix precommit`-эквивалент чист.

---

## Итоговая карта файлов (для быстрой навигации при исполнении)

- **Миграции:** `lib/phoenix_kit_manufacturing/migrations/machines.ex` (М1, М3, М19, М28 — все версии в одном файле, как сейчас).
- **Схемы:** `schemas/machine.ex` (М4), `schemas/machine_type.ex` (М5), `schemas/operation.ex` + `schemas/machine_operation.ex` (М20, новые), `schemas/defect_reason.ex` (М29, новый).
- **Контексты:** `machines.ex` (М6, М22, расширение), `operations.ex` (М21, новый), `defect_reasons.ex` (М30, новый), `attachments.ex` (М10, новый), `comments.ex` (М18, новый), `view_configs.ex` (М14, новый), `column_config.ex` + `column_config/machines.ex` (М15, новые).
- **Web:** `web/machine_form_live.ex` (М7, М12, М18, М27 — самый нагруженный файл волны), `web/machines_live.ex` (М8, М13, М17, М24, М32), `web/machine_type_form_live.ex` (М9), `web/operation_form_live.ex` (М23, новый), `web/defect_reason_form_live.ex` (М31, новый), `web/column_management.ex` + `web/components/column_modal.ex` (М16, новые), `web/components/files_card.ex` (М11, новый), `web/components/comments_panel.ex` (М18, новый).
- **Конфигурация модуля:** `phoenix_kit_manufacturing.ex` (М25, М33 — `admin_tabs/0`), `paths.ex` (М26, М32), `mix.exs` (М2, М18).
