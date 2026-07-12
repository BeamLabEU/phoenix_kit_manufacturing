<!-- РЕШЕНИЯ ОРКЕСТРАТОРА/ВЛАДЕЛЬЦА ПО ОТКРЫТЫМ ВОПРОСАМ (2026-07-12) -->
> **Решения по открытым вопросам:**
> 1. **field_template UI — МИНИ-РЕДАКТОР В МОДУЛЕ (решение владельца)**: новая задача **E18** — маленький LiveView «Шаблон полей» (скрытый tab-роут `manufacturing/machine-types/:uuid/template`, visible:false): переиспользовать существующий UI-паттерн строк {key,label,type,unit,required,options} из удаляемой machine_type_form_live, но читать/писать `data["field_template"]` ЗАПИСИ entities (EntityData.get + update, с валидацией validate_format ключей как сейчас). Ссылки на редактор: из списка записей generic-UI нельзя — поэтому из карточки станка (рядом с бейджем типа, для админа) и прямым роутом; задача также покрывает тест. Остальной CRUD типов — generic entities UI (вариант A сохраняется).
> 2. Локаль-коды set_entity_translation — голые "ru"/"et" (боевой прецедент seed_order_status_entities).
> 3. Согласование с мейнтейнером — подтверждено владельцем ранее (RFC одобрен).
> 4. Пер-операционные ETS-лукапы в list_machine_operations — приемлемо (O(1), справочная кардинальность).
> 5. Сортировка пикеров — position, тай-брейк по title (после сида position=0 у всех → фактически алфавит, дальше — drag-order entities UI).

## Прочитанные артефакты (протокол)

`dev_docs/ENTITIES_MIGRATION_SPEC.md` (целиком, включая §2.5 и §5) · `machines.ex`, `operations.ex`, `defect_reasons.ex` · все 6 схем в `schemas/` · `migrations/machines.ex` (V1–V4) · `web/machine_form_live.ex`, `web/machines_live.ex` · `phoenix_kit_manufacturing.ex` (admin_tabs) · `errors.ex`, `paths.ex`, `column_config/machines.ex`, `gettext.ex`, `mix.exs` · андийские прецеденты `Andi.Orders.StatusRegistry`, `Andi.Orders.SuborderTypes`, `20260502155927_seed_order_status_entities.exs`, `20260502120100_seed_suborder_type_entity.exs`, `20260526062631_migrate_status_entities_to_multilang.exs` · API `phoenix_kit_entities.ex`, `entity_data.ex`, `events.ex`, `routes.ex` · `PhoenixKit.Utils.Multilang` / `MultilangForm` (подтверждён формат `data[lang]["_field"]`) · `PhoenixKit.ModuleRegistry.static_children/0` (механизм `children/0`).

## Цель

Перенести три простых справочника производства (`machine_type`, `operation`, `defect_reason`) из собственных схем/таблиц модуля в `phoenix_kit_entities`, по варианту A (штатный UI entities, стандартные права). Источник истины: `dev_docs/ENTITIES_MIGRATION_SPEC.md` §1–§6.

## Ключевые находки исследования (важны для реализации, не только для протокола)

1. **Мультиязычный формат уже совместим.** `MachineType`/`Operation`/`DefectReason`.`data` уже пишется через core `MultilangForm`/`Multilang.put_language_data` — тот же примитив, что и `EntityData.data`. Переводимые поля хранятся как `data[lang]["_name"]`/`["_description"]` (подтверждено: `machine_type_form_live.ex:46` `@translatable_fields ["name", "description"]`, `operation_form_live.ex:38` `["name"]`, `defect_reason_form_live.ex:35` `["name", "description"]`). Конвертация V5 — это **переименование** `_name` → `_title` (зарезервированный ключ entities, см. `EntityData.get_title_translation/2`, entity_data.ex:2393), а не смена формата контейнера. `_primary_language` копируется как есть.
2. **`_title` живёт только в примари-блоке + оверрайды в остальных.** Примари-language блок несёт ВСЕ значения (переводимые и нет), вторичные — только переопределения переводимых полей (см. `Multilang` moduledoc + `data_form.ex:392-480`). Нетранслируемые кастомные поля (`unit`, `base_time_norm_seconds` у operation) кладутся плоско в примари-блок, без префикса `_`.
3. **`field_template` переживает миграцию как данные, но теряет UI.** Спека прямо говорит: в `fields_definition` нового entity `machine_type` поле `field_template` НЕ объявляется (тривиальный validate_data_against_entity его не трогает — entity_data.ex, `validate_data_against_entity`). Значит после волны E **не будет никакого UI** для создания/правки `field_template` (сейчас это часть `machine_type_form_live.ex`, полностью удаляемого). Это не баг реализации — так спроектировано по спеке, но это реальная потеря функциональности. → см. открытый вопрос №1.
4. **`entity_slug` в маршрутах entities = `entity.name`.** Подтверждено (`data_navigator.ex:106,120`: `params["entity_slug"]` идёт прямо в `Entities.get_entity_by_name/1`). Значит целевые URL — `/admin/entities/machine_type/data`, `/admin/entities/operation/data`, `/admin/entities/defect_reason/data` — без отдельного поля slug на Entity.
5. **`phoenix_kit_entities` — Hex-пакет, но его таблицы создаются миграциями ЯДРА** (`phoenix_kit/lib/phoenix_kit/migrations/postgres/v40.ex`, `v58.ex`, `v74.ex`, `v108.ex`, `v131.ex` и др. содержат `phoenix_kit_entities`). Значит `test_helper.exs` модуля НЕ нужно отдельно мигрировать entities — `PhoenixKit.Migration.ensure_current/2` (уже вызывается) их создаёт как часть цепочки ядра, коль скоро версия `phoenix_kit` в `mix.exs` покрывает нужные версии (сейчас `~> 1.7.133` — покрывает).
6. **`children/0` — штатный колбэк** `PhoenixKit.Module` (default `[]`, module.ex:315), собирается `PhoenixKit.ModuleRegistry.static_children/0` (module_registry.ex:320-339) **до старта реестра**, при загрузке хоста. Новый ETS-реестр модуля добавляется через него — сработает только после **рестарта andi** (не hot-reload, как и всё остальное в path-dep модуле).
7. **`reverse_references` — конфиг на стороне ХОСТА** (`entity_data.ex:1907-1921`, `Application.get_env(:phoenix_kit_entities, :reverse_references, [])`), список `{entity_name, count_fn/1}`. `count_fn` должен уметь посчитать «сколько станков используют этот uuid» — то есть должен вызывать функцию модуля (`PhoenixKitManufacturing.Machines.count_machines_with_type/1`), которую нужно **добавить в модуле**, а конфиг-запись — в andi (ANDI-задача, см. ниже).
8. **Локаль в существующем коде не нормализуется.** `Machines.location_label/2` уже сегодня прокидывает `socket.assigns.locale` (голый gettext-код `"en"/"et"/"ru"`, см. `priv/gettext/{en,et,ru}`) напрямую в `Multilang.get_language_data/2` без маппинга в BCP-47 (`"en-US"` и т.п.), в отличие от андийского `SuborderTypes.normalize_locale/1`. Это существующее, уже принятое поведение модуля — реестр entities заимствует его как есть (см. открытый вопрос №6), не изобретаем новую нормализацию.
9. **`Schemas.Machine.machine_types` (has_many :through)** — единственный реальный потребитель ассоциации, читаемый напрямую (без `linked_type_uuids/1`) — это `enrich_machines/2` в `machines_live.ex:210` (`m.machine_types |> Enum.map(& &1.name)`). После удаления схемы `MachineType` эта ассоциация **обязана** исчезнуть — нужен новый батч-запрос без Ecto-джойна.
10. **`DefectReason` не имеет ни одного потребителя вне своего собственного списка/CRUD** (moduledoc схемы прямым текстом: «this wave does not link defect reasons to machines, operations, or any other resource»). После волны E контекст `DefectReasons` целиком лишний — его читающая часть модулю больше не нужна (в отличие от `machine_type`/`operation`, которым нужен тонкий реестр для пикеров).

## Задачи

Задачи E1–E17 выполняются в `phoenix_kit_manufacturing`. Каждая — отдельный маленький коммит, порядок ниже — порядок зависимостей. Для mix-команд модуля обязательно `PHOENIX_KIT_LOCATIONS_PATH=../phoenix_kit_locations` (иначе `phoenix_kit_locations` резолвится с Hex-плейсхолдера без `PlacePicker`/`Spaces.full_path`, см. `mix.exs:74-77`). Тест-БД в этой среде недоступна — там, где «Проверка» требует Postgres, это явно помечено; по возможности заменять на `mix compile --warnings-as-errors` / `mix credo --strict` / `mix dialyzer`. Миграции применяет оркестратор — задачи миграции (E4–E6) готовят код и тесты, но **не запускаются** агентами волны против реальной БД сверх `mix test.setup`, если он доступен.

---

### E1 — Добавить зависимость `phoenix_kit_entities`

Файл: `mix.exs`.

- В `deps/0` добавить `pk_dep(:phoenix_kit_entities, "~> 0.2.7")` (тем же макросом, что и `phoenix_kit_locations`, строки 70-84).
- В `project/0` → `dialyzer: [plt_add_apps: [...]]` (строка 17) добавить `:phoenix_kit_entities`.
- `application/0` (`extra_applications`, строки 25-29) **не трогать** — модулю не нужен запуск supervision-дерева `phoenix_kit_entities`, только его библиотечные функции + таблицы ядра (см. находку №5/№6).

Проверка: `mix deps.get && mix compile --warnings-as-errors`.

---

### E2 — `PhoenixKitManufacturing.EntitiesRegistry` (ETS + PubSub)

Новый файл: `lib/phoenix_kit_manufacturing/entities_registry.ex`. Смоделировать 1:1 по `Andi.Orders.StatusRegistry` (`/www/app/lib/andi/orders/status_registry.ex`) — GenServer + именованная public ETS-таблица, `Events.subscribe_to_all_data()` + `Events.subscribe_to_entities()` в `init/1`, полный `do_reload/0` на любое `{:data_*, ...}`/`{:entity_*, ...}` сообщение.

Отличия от `StatusRegistry` (диктуются потребителями — machine_form_live picker'ы и `Machines`-контекст):

- `@entity_names %{machine_type: "machine_type", operation: "operation", defect_reason: "defect_reason"}`.
- Кэшируемая запись — не минимальная (`code`/`badge_class`), а несёт всё, что нужны пикерам:
  `%{uuid:, entity_name:, status:, position:, data: <raw data map>, primary_title:, titles: %{locale => title}}`.
  `data` хранится сырым (не только `_title`) — нужен `merged_field_template/1` (читает `data["field_template"]`) и `list_machine_operations/1` (читает `unit`/`base_time_norm_seconds` из примари-блока через `Multilang.get_primary_data/1`).
- Публичное API:
  - `ready?/0`
  - `list(kind, locale, opts \\ [])` — `opts[:status]` (по умолчанию все нетрэшнутые, как в `list_by_entity/2`; вызывающая сторона фильтрует `"published"` там, где раньше было `status: "active"`)
  - `get(uuid, kind)` — единичная запись или `nil`
  - `label(uuid, kind, locale)` — резолвит title по locale → primary → `"Unknown"` (как `StatusRegistry.label/3`)
  - `reload/0`
- `build_kind/2` через `Entities.get_entity_by_name(entity_name)` → `EntityData.list_by_entity(entity.uuid) |> Enum.sort_by(& &1.position)` — тот же паттерн, что `status_registry.ex:145-170`.
- Локаль **не нормализуется** внутри реестра (см. находку №8) — принимает locale как есть и передаёт в `Multilang.get_language_data/2`.

Пока НЕ подключать к `children/0` (следующая задача) — файл автономный, компилируется и тестируется отдельно (юнит-тест на ETS-логику без реальной БД: можно застабить `Entities`/`EntityData` вызовы или пометить `:integration` и пропустить — на усмотрение реализатора, минимум — компиляция).

Проверка: `mix compile --warnings-as-errors`, `mix credo --strict`.

---

### E3 — Подключить `EntitiesRegistry` к supervision-дереву модуля

Файл: `lib/phoenix_kit_manufacturing.ex`.

- Добавить optional-колбэк:
  ```elixir
  @impl PhoenixKit.Module
  def children, do: [PhoenixKitManufacturing.EntitiesRegistry]
  ```
  (рядом с `migration_module/0`, строка ~76).

Проверка: `mix compile --warnings-as-errors`. **Функционально проверяется только на хосте** (andi) после рестарта — `children/0` собирается `ModuleRegistry.static_children/0` при старте приложения (module_registry.ex:320-339), hot-reload не сработает (см. находку №6). Рестарт — ANDI-задача ниже, не в этом репо.

Зависит от: E2.

---

### E4 — Миграция V5: схема + перенос данных (`up/1`, `down/1`)

Файл: `lib/phoenix_kit_manufacturing/migrations/machines.ex`. Это **критический узел** (спека §2.5) — самая рискованная задача волны, делать аккуратно и последовательно, с явными шагами внутри одного (кумулятивного, как и остальные версии) `up/1`.

1. `@current_version 4` → `5` (строка 86).
2. В конец `up/1` (после блока «V4: defect reasons directory», строка ~385) добавить блок «V5: migrate machine_type/operation/defect_reason to phoenix_kit_entities», в таком порядке (порядок важен — `up/1` кумулятивен, то есть V1-V4 CREATE TABLE выполняются заново при каждом повторном вызове; блок V5 обязан снова смигрировать+дропнуть, иначе повторный `mix phoenix_kit.update` молча воскресит пустые старые таблицы):
   - **a. Ensure 3 blueprint-сущности** (идемпотентно, `PhoenixKitEntities.get_entity_by_name/1` → если `nil`, `create_entity/2` + `set_entity_translation/3` для ru/et, по рецепту `20260502155927_seed_order_status_entities.exs:117-139`):
     - `machine_type` — `fields_definition: [%{"type" => "textarea", "key" => "description", "label" => "Description", "translatable" => true}]` (никакого поля под `field_template` — см. находку №3), `icon: "hero-tag"`.
     - `operation` — `fields_definition: [%{"type" => "text", "key" => "unit", "label" => "Unit"}, %{"type" => "number", "key" => "base_time_norm_seconds", "label" => "Base time norm (seconds)"}]` (обе НЕ `translatable`), `icon: "hero-clock"`.
     - `defect_reason` — как у `machine_type` (`description`, translatable), `icon: "hero-exclamation-triangle"`.
     - display_name/plural + ru/et переводы — предложить дефолтные строки («Machine Type»/«Типы станков»/…), финальную копию согласовать с мейнтейнером/владельцем при ревью PR — не блокирует реализацию.
   - **b. Перенос строк**, для каждой из трёх старых таблиц (читать **сырым SQL** через `repo().query/2`, а не через удаляемые Ecto-схемы — так же, как уже делают `table_exists?/2`/`column_exists?/2` в этом же файле, строки 429-455 — миграция не должна зависеть от того, существуют ли ещё Ecto-схемы `MachineType`/`Operation`/`DefectReason` в кодовой базе на момент выполнения):
     - Идемпотентность: перед вставкой проверять существование записи с `data->>'legacy_uuid' = <old uuid>` в `phoenix_kit_entity_data` этого entity (spec §2 п.2). Если найдена — пропустить (не создавать дубликат), но **обязательно всё равно** учитывать её uuid в маппинге old→new для шага (c).
     - Конвертация мультиязычности (находка №1/№2): взять старый `data` (`%{"_primary_language" => lang, lang => %{"_name" => ..., "_description" => ...}, other_lang => %{"_name" => ...}}`), для каждого lang-блока: `_name` → `_title`; `_description` остаётся `_description` (уже объявлено `translatable` в fields_definition, п. a); `_primary_language` копируется как есть. Если у старой записи `data` пуст/не мультиязычен (Languages-модуль не был включён) — примари-блок строится из плоских `name`/`description` колонок, `_primary_language` берётся из `PhoenixKit.Utils.Multilang.primary_language/0`.
     - Для `operation`: в примари-language блок дополнительно (без `_`-префикса, см. находку №2) кладутся `"unit"` и `"base_time_norm_seconds"` из старых плоских колонок.
     - Для `machine_type`: в `data` (вне per-lang блоков, как top-level ключ, находка №3) копируется старый `field_template` как есть.
     - `status`: старое `"active"` → `"published"`, `"inactive"` → `"draft"`.
     - `data["legacy_uuid"]` = старый uuid (top-level, вне lang-блоков) — маркер идемпотентности п. выше.
     - Вставка через `PhoenixKitEntities.EntityData.create/2` (не raw SQL insert — даёт бесплатно `position`/`created_by_uuid`/PubSub-событие, тот же выбор, что в `seed_order_status_entities.exs:160-173`); `title:` = title примари-языка (для колонки `title`).
   - **c. Маппинг**: собрать `%{old_uuid => new_entity_data_uuid}` по обеим таблицам (`machine_type`, `operation`) из результатов шага b (включая уже существовавшие при повторном запуске).
   - **d. Перешивка ссылок**: для каждой пары маппинга — `UPDATE #{p}phoenix_kit_machine_type_assignments SET machine_type_uuid = $2 WHERE machine_type_uuid = $1` (параметризованный `execute`/`repo().query`), аналогично `operation_uuid` в `phoenix_kit_machine_operations`. Только для `machine_type`/`operation` — `defect_reason` ни на что не ссылается (находка №10), маппинг для него не нужен за пределами шага b.
   - **e. Снятие FK**: обнаружить реальное имя constraint'а через `information_schema.table_constraints`/`key_column_usage` (не хардкодить `..._fkey` — устойчиво к возможному переименованию) и `ALTER TABLE ... DROP CONSTRAINT IF EXISTS <found_name>` для `phoenix_kit_machine_type_assignments.machine_type_uuid` и `phoenix_kit_machine_operations.operation_uuid`. Вынести это обнаружение в приватный хелпер `fk_constraint_name(prefix, table, column)` — переиспользуется в E5 (probe).
   - **f. `DROP TABLE IF EXISTS #{p}phoenix_kit_machine_types/phoenix_kit_operations/phoenix_kit_defect_reasons CASCADE`.**
3. `down/1` (строки 403-415): заменить тело целиком на документированный raise, например:
   ```elixir
   def down(_opts \\ []) do
     raise """
     PhoenixKitManufacturing.Migrations.Machines V5 rollback is not supported.
     machine_type/operation/defect_reason data now lives in phoenix_kit_entities;
     rolling back would require reconstructing three tables from entity_data with
     no guaranteed inverse mapping. Restore from a pre-V5 database backup instead.
     """
   end
   ```
   (spec §2 п.6 — «no-op с raise», ничего не удалять/не создавать перед raise).
4. Обновить moduledoc (строки 1-80): таблица версий (добавить V5), абзац про `down/1` (полный откат уже не «drop all six tables», а raise), убрать `phoenix_kit_machine_types`/`phoenix_kit_operations`/`phoenix_kit_defect_reasons` из списка «This module ships».

Зависит от: ничего технически (можно делать параллельно с E1-E3), но логически раньше остального кода-уровня (E7+), т.к. описывает целевую форму данных, на которую они опираются.

Проверка: `mix compile --warnings-as-errors`. Полная проверка данных — в E6 (интеграционные тесты, требуют Postgres) и на реальном хосте — оркестратором.

---

### E5 — Миграция V5: редизайн `version_probes/0`

Файл: `lib/phoenix_kit_manufacturing/migrations/machines.ex` (тот же, отдельный коммит от E4 — независимая логическая единица: E4 меняет данные, E5 — детекцию версии).

- Добавить `probe_v5?/1`, проверяющий **кумулятивное состояние «как после V5»** (spec §2 п.5): отсутствие всех трёх старых таблиц (`table_exists?` == false для `phoenix_kit_machine_types`/`phoenix_kit_operations`/`phoenix_kit_defect_reasons`) **и** отсутствие обоих FK-констрейнтов (переиспользовать `fk_constraint_name/3` из E4 → `is_nil(...)`) **и** присутствие `phoenix_kit_machines`/`phoenix_kit_machine_types`… стоп — `phoenix_kit_machine_types` дропнута, значит вместо неё как санитарная проверка «база не пустая/не сломанная» — наличие всех `@v2_columns` на `phoenix_kit_machines` (переиспользовать существующий список, строки 139-151) плюс `table_exists?(prefix, "phoenix_kit_machine_type_assignments")` и `table_exists?(prefix, "phoenix_kit_machine_operations")` (join-таблицы остаются).
- Добавить `{5, &probe_v5?/1}` в `version_probes/0` (строка ~116-123), в конец списка (комментарий на строке 113 явно требует «Extend this list (never rewrite past entries)» — v1-v4 не трогать, они и не ломаются: `migrated_version_runtime/1` идёт от старшей версии к младшей и останавливается на первом `true`, так что для полностью смигрированного V5-хоста `probe_v5?` сработает первым и v3/v4 (которые бы вернули `false` на V5-хосте) никогда не проверяются — см. находку в исследовании про порядок обхода).
- Обновить секцию moduledoc «Version detection» (строки 59-70): описать, что после V5 старые табличные пробы (v3/v4) больше не «действительны» на V5-хосте, но это безопасно именно благодаря порядку `Enum.sort_by(..., :desc) |> Enum.find_value`.

Проверка: `mix compile --warnings-as-errors`, `mix dialyzer` (список пробов типизирован `[{pos_integer(), (String.t() -> boolean())}]` — новая пара должна пройти spec).

Зависит от: E4 (использует `fk_constraint_name/3`, определённый там).

---

### E6 — Интеграционные тесты миграции V5

Файл: `test/phoenix_kit_manufacturing/migrations/machines_test.exs`.

Добавить (все `:integration`, требуют Postgres — **в этой песочнице не запускаются**; проверка отложена до `mix test.setup && mix test --only integration` на хосте с БД):

1. **«Свежий хост сразу V5»** — на пустой БД вызвать `Machines.up(prefix: "public")` один раз; assert: `migrated_version_runtime(prefix: "public") == 5`; три старых таблицы не существуют; оба FK отсутствуют; в `phoenix_kit_entities` появились 3 blueprint-а с ожидаемыми `name`; `EntityData.list_by_entity(...)` пуст для всех трёх (свежий хост — нет legacy-строк для переноса).
2. **«V4-хост апгрейдится до V5»** — перед вызовом `up/1` руками (raw SQL insert, через `Ecto.Adapters.SQL.query!`) насеять 2-3 строки в `phoenix_kit_machine_types`/`phoenix_kit_operations`/`phoenix_kit_defect_reasons` + связи в `phoenix_kit_machine_type_assignments`/`phoenix_kit_machine_operations`, включая мультиязычный `data` (`_primary_language`/`_name`/`_description`) и однажды — запись БЕЗ мультиязычного `data` (плоские `name`/`description`, эмулирует хост без Languages-модуля). Вызвать `up/1`; assert: перенесённые `EntityData` несут правильные `_title`/`_description` по языкам, `status` корректно смаппился (active→published/inactive→draft), `field_template`/`unit`/`base_time_norm_seconds` сохранились; `machine_type_assignments.machine_type_uuid`/`machine_operations.operation_uuid` указывают на НОВЫЕ uuid; старые таблицы дропнуты.
3. **Идемпотентность** — вызвать `up/1` дважды подряд на насеянных данных из теста 2; assert: количество `EntityData` для каждого entity не удвоилось, маппинг ссылок не съехал (второй прогон «CREATE (пусто) → migrate (0 строк) → DROP» безвредно ноуопит, см. E4 п.2 преамбулу).
4. **`down/1` бросает** — `assert_raise(RuntimeError, fn -> Machines.down(prefix: "public") end)`, БД не тронута (таблицы entities целы).

Проверка: (когда БД доступна) `mix test.setup && mix test test/phoenix_kit_manufacturing/migrations/machines_test.exs`. В этой среде — как минимум `mix compile --warnings-as-errors` на сам тестовый файл (синтаксис/типы).

Зависит от: E4, E5.

---

### E7 — Схемы join-таблиц: снять FK/ассоциации на удаляемые схемы

Файлы: `schemas/machine_type_assignment.ex`, `schemas/machine_operation.ex`, `schemas/machine.ex`.

- `schemas/machine_type_assignment.ex:19-23` — заменить `belongs_to(:machine_type, PhoenixKitManufacturing.Schemas.MachineType, ...)` на плоское `field(:machine_type_uuid, UUIDv7)`; из `changeset/2` (строки 36-42) убрать `|> assoc_constraint(:machine_type)` (список `cast/2` не меняется — `:machine_type_uuid` уже там по имени). `belongs_to(:machine, ...)` и `assoc_constraint(:machine)` — не трогать.
- `schemas/machine_operation.ex:25-29` — аналогично: `belongs_to(:operation, ...)` → `field(:operation_uuid, UUIDv7)`, убрать `assoc_constraint(:operation)` из `changeset/2` (строки 47-54). `belongs_to(:machine, ...)` не трогать.
- `schemas/machine.ex:76-81` — удалить `has_many(:machine_types, through: [:machine_type_assignments, :machine_type])` (ссылается на удаляемую схему `MachineType` — иначе не скомпилируется). `has_many(:machine_type_assignments, ...)` оставить.

Проверка: `mix compile --warnings-as-errors` **упадёт** на этом шаге, если оставить вызовы `preload: [:machine_types]`/`repo().preload(machine, :machine_types)` в `machines.ex` — это ожидаемо, они правятся в E9 следующим коммитом. Если хочется зелёной сборки на каждом шаге — сделать E7+E9 одним коммитом (граница между ними формальная, оба меняют один слой).

Зависит от: ничего (можно параллельно с E1-E6).

---

### E8 — Удалить схемы `MachineType`/`Operation`/`DefectReason`

Файлы к удалению:
- `lib/phoenix_kit_manufacturing/schemas/machine_type.ex`
- `lib/phoenix_kit_manufacturing/schemas/operation.ex`
- `lib/phoenix_kit_manufacturing/schemas/defect_reason.ex`
- `test/phoenix_kit_manufacturing/schemas/machine_type_test.exs`
- `test/phoenix_kit_manufacturing/schemas/operation_test.exs`
- `test/phoenix_kit_manufacturing/schemas/defect_reason_test.exs`

Проверка: `mix compile` — будет падать (много мест ссылаются на эти алиасы) до завершения E9-E13; это ожидаемо для промежуточного коммита. Финальная зелёная сборка проверяется в E13/E15.

Зависит от: E7 (тот же логический слой «убрать всё, что ссылается на удаляемые схемы», порядок внутри не строгий — можно объединить E7+E8 в один коммит, если удобнее одной атомарной правкой).

---

### E9 — `Machines` контекст: чтение через `EntitiesRegistry`, снос write-side для типов

Файл: `lib/phoenix_kit_manufacturing/machines.ex`.

- `list_machine_types/1` (строки 67-73): заменить тело на `EntitiesRegistry.list(:machine_type, locale, status: ...)`. Сигнатура меняется на `list_machine_types(locale, opts \\ [])` **или** оставить kw-list `list_machine_types(opts \\ [])` с `opts[:locale]`/`opts[:status]` — выбрать второе (меньше правок на стороне вызывающих, единообразно с существующим стилем модуля, например `location_label/2`). Дефолт `opts[:status]` — не задавать (пусть вызывающая сторона явно передаёт `"published"`, как раньше явно передавала `"active"`).
- `get_machine_type/1` (76-77), `get_machine_type_by_name/1` (79-81), `count_machine_types/1` (83-90), `create_machine_type/2` (92-100), `update_machine_type/2` (102-110), `delete_machine_type/2` (112-119), `change_machine_type/2` (121-125) — **удалить целиком** (CRUD теперь только через `/admin/entities/machine_type/data`). Перед удалением проверить `grep -rn "Machines\.\(get_machine_type\b\|get_machine_type_by_name\|count_machine_types\|create_machine_type\|update_machine_type\|delete_machine_type\|change_machine_type\)"` по `lib/`+`test/` — все живые вызовы должны находиться внутри файлов, которые сами удаляются в E11/E12/E8; если найдётся что-то ещё — разобраться прежде чем удалять.
- `list_machines/1` (139-160) и `get_machine/1` (162-169): убрать `preload: [:machine_types]` / `repo().preload(machine, :machine_types)` (ассоциация снесена в E7).
- НОВОЕ: `linked_type_uuids_by_machine/1` — принимает список `machine_uuid`, один батч-запрос `from(a in MachineTypeAssignment, where: a.machine_uuid in ^uuids, select: {a.machine_uuid, a.machine_type_uuid}) |> repo().all() |> Enum.group_by(...)`, возвращает `%{machine_uuid => [type_uuid, ...]}`. Заменяет снесённый `preload: :machine_types` для `machines_live.enrich_machines/2` (находка №9) — без него там будет N+1/сломанная ассоциация.
- `merged_field_template/1` (552-586): заменить `list_machine_types(status: "active")` на `EntitiesRegistry.list(:machine_type, locale, status: "published")` (locale нужно прокинуть аргументом — `merged_field_template/2` с `locale \\ nil`, т.к. label не используется в мердже, но сам вызов регистра требует locale-параметр; можно передавать `nil`, если реестр это терпит — свериться с E2-реализацией) и читать `field_template` из `record.data["field_template"] || []` вместо `%MachineType{field_template: ...}` (docstring про «first wins» слияние — не менять, логика слияния не завязана на источник данных).
- `list_machine_operations/1` (330-342): убрать `join: o in assoc(mo, :operation)` (ассоциация снесена в E7); вместо джойна — `from(mo in MachineOperation, where: mo.machine_uuid == ^machine_uuid) |> repo().all()`, затем для каждой строки `EntitiesRegistry.get(mo.operation_uuid, :operation)` → собрать `%{operation: <map c :uuid,:name,:unit,:base_time_norm_seconds,:status>, time_norm_seconds: mo.time_norm_seconds}`; сортировку `order_by: [asc: o.name]` заменить на `Enum.sort_by(&(&1.operation.name || ""))` после резолва (SQL-сортировка по имени операции больше недоступна — имя не в этой таблице).
- НОВОЕ: `count_machines_with_type/1` и `count_machines_with_operation/1` — простые `from(a in MachineTypeAssignment, where: a.machine_type_uuid == ^uuid, select: count()) |> repo().one()` (и аналогично для `MachineOperation`/`operation_uuid`) — для ANDI-задачи `reverse_references` ниже.
- Добавить `alias PhoenixKitManufacturing.EntitiesRegistry` в шапку модуля; убрать `alias ... Operation` из списка `Schemas.{...}` (строки 40-46), если `Operation` больше нигде в файле не используется после правок выше.
- Актуализировать moduledoc (строки 1-31): убрать «Both machines and types use hard-delete only» (типы больше не хард-делитятся этим модулем вообще — они под entities-трэшем), поправить пример из `## Usage from IEx` (там `Machines.create_machine_type/1` — больше не существует).

Проверка: `mix compile --warnings-as-errors`.

Зависит от: E2 (реестр), E7/E8 (схемы).

---

### E10 — Удалить контексты `Operations`/`DefectReasons`

Файлы к удалению:
- `lib/phoenix_kit_manufacturing/operations.ex`
- `lib/phoenix_kit_manufacturing/defect_reasons.ex`
- `test/phoenix_kit_manufacturing/operations_test.exs`
- `test/phoenix_kit_manufacturing/defect_reasons_test.exs`

Обоснование: `Operations`' read-side полностью переехал в `EntitiesRegistry`+`Machines` (E9); write-side удалён по варианту A. `DefectReasons` не имеет вообще ни одного потребителя вне своего собственного CRUD/списка (находка №10) — переносить туда нечего, контекст просто исчезает.

Проверка: `mix compile` (упадёт до E11-E13 — ожидаемо для промежуточного коммита, как в E8).

Зависит от: E9.

---

### E11 — `machine_form_live.ex`: пикеры через реестр

Файл: `lib/phoenix_kit_manufacturing/web/machine_form_live.ex`.

- `alias PhoenixKitManufacturing.{Attachments, Comments, Errors, Machines, Operations, Paths}` (строка 141) → убрать `Operations`, добавить `EntitiesRegistry`.
- `alias PhoenixKitManufacturing.Schemas.{Machine, Operation}` (строка 142) → убрать `Operation` (схема удалена в E8).
- `safe_list_types/0` (276-282): `Machines.list_machine_types(status: "active")` → `Machines.list_machine_types(locale: socket_locale, status: "published")` — нужно прокинуть locale в функцию (сейчас `safe_list_types/0` без аргументов вызывается из `load_new/1`:192 и `assign_edit_buffer/2`:247 — оба уже внутри функций, у которых есть `socket`, добавить параметр `safe_list_types(locale)`).
- `safe_list_operations/0` (292-298): аналогично, `Operations.list_operations(status: "active")` → `EntitiesRegistry.list(:operation, locale, status: "published")`.
- `safe_merged_template/1` (284-290): вызов `Machines.merged_field_template/1` — сигнатура меняется в E9 (может понадобиться locale-аргумент, свериться и прокинуть).
- Все места, где типы/операции показываются как badges (`t.name`, строка 821) — тип записи из реестра теперь plain map с ключом `:primary_title`/`:titles`; заменить `t.name` на `EntitiesRegistry.label`-подобное поле (например резолвить label один раз при построении `all_types`, положить готовую строку в `:label` перед рендером, чтобы шаблон не трогать сильно).
- `attr(:operation, Operation, required: true)` (строка 1003) → `attr(:operation, :map, required: true)`.
- `operation_label/1` (1033-1036), `operation_base_hint/1` (1038-1039), `operation_override_placeholder/1` (1041-1045) — заменить деструктуризацию `%Operation{name: name, unit: unit, base_time_norm_seconds: base}` на доступ по ключам map (`operation.name`, `operation.unit`, `operation.base_time_norm_seconds`) — сохранить точно те же имена ключей в реестровой записи (E2), чтобы диф был минимальным.
- `merged_field_template`/дальнейший код секции «Dynamic metadata fields» (строки 61-68 модуледока, `dynamic_metadata_field/1` компонент) — логика не меняется, источник данных (`row` из `@merged_template`) остаётся тем же списком map'ов, просто теперь приходящим из `data["field_template"]` записи entity, а не из колонки схемы; проверить, что формат строки `field_template` (ключи `key`/`label`/`type`/`unit`/`required`/`options`) прошёл миграцию E4 без искажений (JSON as-is copy — должен).

Проверка: `mix compile --warnings-as-errors`, `mix format --check-formatted`.

Зависит от: E9, E2.

---

### E12 — Удалить `machine_type_form_live.ex` / `operation_form_live.ex` / `defect_reason_form_live.ex`

Файлы к удалению:
- `lib/phoenix_kit_manufacturing/web/machine_type_form_live.ex`
- `lib/phoenix_kit_manufacturing/web/operation_form_live.ex`
- `lib/phoenix_kit_manufacturing/web/defect_reason_form_live.ex`
- `test/phoenix_kit_manufacturing/web/machine_type_form_live_test.exs`
- `test/phoenix_kit_manufacturing/web/operation_form_live_test.exs`
- `test/phoenix_kit_manufacturing/web/defect_reason_form_live_test.exs`

Проверка: `mix compile` (упадёт до E14 — `phoenix_kit_manufacturing.ex` всё ещё ссылается на эти модули в `admin_tabs/0`; ожидаемо для промежуточного коммита).

Зависит от: E11 (после того как `machine_form_live.ex` перестал нуждаться в `Operation`-схеме и т.п., хотя формально эти три файла независимы — можно и раньше).

---

### E13 — `machines_live.ex`: снести списки типов/операций/причин брака, редиректить подтабы

Файл: `lib/phoenix_kit_manufacturing/web/machines_live.ex`.

- `mount/3` (76-110): убрать инициализацию `machine_types: []`, `operations: []`, `defect_reasons: []`.
- `handle_params/3` (112-125) не меняется по структуре, но для `live_action in [:types, :operations, :defect_reasons]` `load_data/2` (см. ниже) теперь делает редирект вместо загрузки данных.
- `load_data(socket, :types)` (164-170), `load_data(socket, :operations)` (172-178), `load_data(socket, :defect_reasons)` (180-186) — заменить все три на **один** редирект-паттерн:
  ```elixir
  defp load_data(socket, action) when action in [:types, :operations, :defect_reasons] do
    push_navigate(socket, to: entities_redirect_path(action))
  end

  defp entities_redirect_path(:types), do: Paths.types()
  defp entities_redirect_path(:operations), do: Paths.operations()
  defp entities_redirect_path(:defect_reasons), do: Paths.defect_reasons()
  ```
  (`Paths.types/0` и т.д. сами становятся entities-URL в E14 — здесь просто вызов).
- Удалить: `tab_title(:types)`/`tab_title(:operations)`/`tab_title(:defect_reasons)` и `tab_subtitle(:types)`/`tab_subtitle(:operations)`/`tab_subtitle(:defect_reasons)` (144-152) — редиректная страница не рендерится, `page_title`/`page_subtitle` для этих трёх live_action больше не читаются (можно оставить общий `tab_subtitle(_action)` дефолт как есть).
- `enrich_machines/2` (206-230): заменить `type_names = m.machine_types |> Enum.map(& &1.name) |> Enum.sort()` — ассоциация снесена (E7). Новый порядок: batch `Machines.linked_type_uuids_by_machine(Enum.map(machines, & &1.uuid))` **до** `Enum.map`, затем на каждой строке `type_names = uuid_map |> Map.get(m.uuid, []) |> Enum.map(&EntitiesRegistry.label(&1, :machine_type, locale)) |> Enum.sort()`.
- Удалить целиком: `types_table/1` (1075-1171), `operations_table/1` (1175-1276), `defect_reasons_table/1` (1285-1381), `format_duration/1` (1059-1068, использовался только `operations_table`), делит-хендлеры и связанные ветки `handle_event("delete_machine_type"/"delete_operation"/"delete_defect_reason", ...)` (382-401), `fetch_for_delete(:machine_type/:operation/:defect_reason, ...)` (451-453), `delete_for_kind(:machine_type/:operation/:defect_reason, ...)` (458-465), `deleted_message`/`not_found_atom`/`delete_failed_atom`/`reload_action` — их клозы для `:machine_type`/`:operation`/`:defect_reason` (467-486), три `<.confirm_modal>` в `render/1` (744-775) для этих трёх типов.
- В `render/1` убрать `<div :if={@active_tab == :types}>`/`:operations`/`:defect_reasons` блоки (721-731) — эти live_action теперь никогда не рендерят страницу (редирект в `handle_params`), только `:index` остаётся содержательным.
- `machines_tab_bar/1` (788-817): ссылки на Types/Operations/Defect Reasons (`Paths.types()`/`.operations()`/`.defect_reasons()`) продолжают работать без изменений — теперь ведут сразу на entities (E14), минуя редирект-хоп даже для этого локального таб-бара. `@active == :types` и т.п. подсветка станет мёртвым кодом (live_action `:types` никогда фактически не рендерится) — можно упростить/оставить как есть, не блокирующая правка.
- `status_label/1` (1433-1439) / `status_badge_class/1` (1441-1448): ветка `"inactive"` была нужна только для MachineType/Operation/DefectReason (`Machine.statuses/0` не включает `"inactive"`) — теперь мёртвая, можно удалить как мелкую чистку (не обязательно для компиляции).

Тесты (`test/phoenix_kit_manufacturing/web/machines_live_test.exs`):
- Удалить: `"types list renders the empty state"` (15-19), `"operations list renders the empty state"` (21-25) + оба operations-теста (27-49), `"defect reasons list renders the empty state"` (51-55) + оба defect_reasons-теста (57-79), `"deleting an operation removes it from the list"` (213-225), `"cancelling an operation delete leaves it in the list"` (227-239), `"deleting a defect reason removes it from the list"` (241-253), `"cancelling a defect reason delete leaves it in the list"` (255-267).
- **Тест последнего таба** (задание оркестратора явно требует покрытие): заменить удалённые тесты новым `describe "entities redirects"` с тремя тестами — переход на `live_action: :types/:operations/:defect_reasons` (`live(conn, Paths.machines() <> "/types")` и т.п.) приводит к `assert_redirect(view, Paths.types())` (и аналогично для operations/defect_reasons — **defect_reasons — самый свежий/последний добавленный подтаб**, обязателен к покрытию явно, не полагаться на «типы протестируют паттерн, остальное аналогично»).
- `"a machine's type name appears as a badge in the Types column"` (108-119): не удалять — адаптировать под новый способ создания привязки (раньше вызывался несуществующий уже `Machines.create_machine_type/1`).

Проверка: `mix compile --warnings-as-errors`. Тест-файл — `mix compile` пройдёт (юнит-уровень), полный `mix test` (LiveView-тесты — `:integration`, нужна БД) — best-effort, недоступно в этой среде.

Зависит от: E9 (батч-функция), E2 (реестр), E14 (Paths — можно писать параллельно, `Paths` — крошечный файл).

---

### E14 — `Paths.ex` / `Errors.ex`

Файл: `lib/phoenix_kit_manufacturing/paths.ex`.

- `types/0` (46-48): `Routes.path("#{@base}/machines/types")` → `Routes.path("/admin/entities/machine_type/data")`.
- `operations/0` (60-62): → `Routes.path("/admin/entities/operation/data")`.
- `defect_reasons/0` (74-76): → `Routes.path("/admin/entities/defect_reason/data")`.
- Удалить: `type_new/0` (50-52), `type_edit/1` (54-56), `operation_new/0` (64-66), `operation_edit/1` (68-70), `defect_reason_new/0` (78-80), `defect_reason_edit/1` (82-84).
- Обновить `@moduledoc` — уточнить, что `types/0`/`operations/0`/`defect_reasons/0` указывают на entities admin UI, не на собственные маршруты модуля.

Файл: `lib/phoenix_kit_manufacturing/errors.ex`. Удалить клозы `message/1` для `:machine_type_not_found` (28), `:operation_not_found` (29), `:defect_reason_not_found` (30), `:machine_type_delete_failed` (32), `:operation_delete_failed` (33), `:defect_reason_delete_failed` (34). Оставить `:machine_not_found`, `:machine_delete_failed`, `:type_assignment_failed`, `:operation_assignment_failed`, `:unexpected`.

Проверка: `mix compile --warnings-as-errors`, `grep -rn "Errors.message(:machine_type_not_found\|:operation_not_found\|:defect_reason" lib/ test/` — пусто.

Зависит от: E13 (использует `Paths.types()`/etc в редиректах — по факту можно делать этот коммит первым, порядок E13/E14 между собой не строгий, но `Paths.ex` логичнее закрыть первым, чтобы E13 сразу опирался на финальные URL).

---

### E15 — `phoenix_kit_manufacturing.ex`: `admin_tabs/0`

Файл: `lib/phoenix_kit_manufacturing.ex`, `admin_tabs/0` (89-342).

Удалить Tab-записи: `:manufacturing_type_new` (196-209), `:manufacturing_operation_new` (210-223), `:manufacturing_defect_reason_new` (224-237), `:manufacturing_type_edit` (239-252), `:manufacturing_operation_edit` (313-326), `:manufacturing_defect_reason_edit` (327-340) — их `live_view:` указывает на удалённые в E12 модули.

Оставить без изменений: `:manufacturing_types` (142-154), `:manufacturing_operations` (155-167), `:manufacturing_defect_reasons` (168-180) — всё ещё маршрутизируются на `MachinesLive` (теперь редирект-only, E13), `path:`/`priority:`/`permission:` не меняются (URL модуля `/admin/manufacturing/machines/types` и т.п. остаётся валидным и присутствует в сайдбаре — просто мгновенно редиректит).

Проверка: `mix compile --warnings-as-errors`; `iex -S mix` → `PhoenixKitManufacturing.admin_tabs() |> Enum.map(& &1.id)` — сверить, что удалённых id больше нет, а `:manufacturing_types`/`:manufacturing_operations`/`:manufacturing_defect_reasons` остались.

Зависит от: E12 (удалённые LiveView-модули должны физически отсутствовать до/одновременно с этим коммитом — либо объединить E12+E15 в один коммит, чтобы не было промежуточного некомпилируемого состояния).

---

### E16 — i18n

Команды (в директории модуля, с `PHOENIX_KIT_LOCATIONS_PATH` в окружении):
```
mix gettext.extract
mix gettext.merge priv/gettext
```
- Проверить diff по всем трём локалям (`priv/gettext/{en,et,ru}/LC_MESSAGES/default.po`) — новые/удалённые msgid должны соответствовать удалённым строкам форм (`"New Type"`, `"Edit Type"`, `"New Operation"`, …) и любым новым строкам, введённым в E4 (entity `display_name`/переводы — если они идут через gettext, а не хардкод в миграции; в данном случае они хардкожены в миграции как обычные строки/атрибуты entity, НЕ через `gettext/1`, так что extract их не тронет — только явные `gettext(...)`-вызовы в оставшемся коде).
- По прецеденту памяти `gettext.merge` может продуцировать fuzzy-мэтчи на посторонние близкие строки — вручную сверить English-каталог построчно на осмысленность (не полагаться только на диф).

Проверка: `mix compile --warnings-as-errors` (gettext ошибки компиляции ловятся на этом шаге), визуальный дифф `.po`-файлов.

Зависит от: E9, E11, E13, E14, E15 (все источники `gettext/1`-вызовов должны быть в финальном виде).

---

### E17 — Актуализация moduledoc/AGENTS.md модуля

Файлы:
- `phoenix_kit_manufacturing/CLAUDE.md` (он же `AGENTS.md`) — секция «File layout» (список файлов): убрать `schemas/{machine_type,operation}.ex`, добавить `entities_registry.ex`; секция «Key conventions» — добавить абзац: «machine_type/operation/defect_reason live in `phoenix_kit_entities` as of vX.Y — see `PhoenixKitManufacturing.EntitiesRegistry`, edited via `/admin/entities/:slug/data`, not module-owned CRUD»; уточнить «Database & migrations» — таблицы `phoenix_kit_machine_types`/`phoenix_kit_operations`/`phoenix_kit_defect_reasons` больше не существуют с V5, перечислить актуальный список (`phoenix_kit_machines`, `phoenix_kit_machine_type_assignments`, `phoenix_kit_machine_operations`).
- `lib/phoenix_kit_manufacturing.ex` — верхний `@moduledoc` (строки 1-13): формулировка «machines and their (many-to-many) machine types» — уточнить, что типы теперь entities-backed.
- `lib/phoenix_kit_manufacturing/machines.ex` — moduledoc (см. также E9).
- `dev_docs/DEVELOPMENT_PLAN.md` (если там перечислены Types/Operations/Defect Reasons как часть модуля — сверить и поправить статус на «entities-backed»).

Проверка: чтение глазами, `mix docs` (если используется в проекте) не обязателен, но не должен падать.

Зависит от: E9-E15 (описывает финальное состояние).

---

## ANDI-задача (для оркестратора — НЕ выполняется агентами волны E в `/www/app`)

Реализуется в `/www/app` после того, как `phoenix_kit_manufacturing` с волной E закоммичен (и, если публикуется на Hex — после публикации; при локальной разработке через `PHOENIX_KIT_MANUFACTURING_PATH`, если такой env поддержан в andi's mix.exs, или прямой path-dep, как сейчас).

1. **`reverse_references` конфиг** — в `/www/app/config/config.exs` добавить:
   ```elixir
   config :phoenix_kit_entities,
     reverse_references: [
       {"machine_type", &PhoenixKitManufacturing.Machines.count_machines_with_type/1},
       {"operation", &PhoenixKitManufacturing.Machines.count_machines_with_operation/1}
     ]
   ```
   (функции добавлены в модуле, задача E9). Если уже есть существующая запись `reverse_references` (например, от `order_status`/`suborder_type`) — дописать в существующий список, не перезаписать.
2. **Рестарт**: `sudo /usr/bin/supervisorctl restart elixir` — обязателен дважды по независимым причинам: (a) `phoenix_kit_manufacturing` — path-dep, не hot-reload (память `feedback_path_dep_reload.md`); (b) `children/0` (E3) — собирается при старте приложения, не при recompile.
3. **Применение миграции V5**: `mix phoenix_kit.update` (per project convention — один командой генерит+применяет; см. память `feedback_phoenix_kit_update.md`). Желательно на хосте, где реально есть legacy-строки в `phoenix_kit_machine_types`/`phoenix_kit_operations`/`phoenix_kit_defect_reasons`, чтобы по-настоящему прогнать путь переноса данных (E4 п.b), а не только «пустой хост».
4. **Runtime-проверка** (Tidewave/браузер):
   - `PhoenixKitManufacturing.EntitiesRegistry.ready?()` → `true`.
   - `/admin/manufacturing/machines/types` редиректит на `/admin/entities/machine_type/data` (аналогично operations/defect-reasons).
   - На `/admin/entities/machine_type/data` — записи с правильными title/переводами, `field_template`-значения видны в сыром `data` (нет UI-виджета — ожидаемо, см. открытый вопрос №1) при попытке trash — hint «used by N machines» отражает реальные привязки.
   - Форма станка (`/admin/manufacturing/machines/:uuid/edit`) — пикер типов/операций работает, `merged_field_template` рендерит специфичные поля, сохранение синкает `machine_type_assignments`/`machine_operations` по новым uuid.
5. Отчитаться перед owner о факте выполнения upstream-согласования (spec §6 — RFC/issue мейнтейнеру ДО реализации; если не сделано, задача блокирует старт волны E целиком, не только ANDI-часть).

## Порядок применения миграции

Только оркестратор запускает `mix phoenix_kit.update`/эквивалент против реальной БД (инструкция задания). Локально в песочнице волны E — максимум `mix test.setup` (если Postgres доступен) для юнит/интеграционных тестов E6; полный прогон на живых legacy-данных — ANDI-задача п.3 выше.