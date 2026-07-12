# Спецификация: перенос простых справочников производства в phoenix_kit_entities

Дата: 2026-07-11. Решение владельца: Типы станков, Операции, Причины брака — из схем модуля в entities; все будущие простые справочники — сразу entities. Основание-прецедент: andi уже так живёт (Andi.Orders.StatusRegistry / FinancialStatusRegistry / SuborderTypes + seed-миграции 20260502*). Исследование API — 2026-07-11 (file:line в отчёте).

## 1. Целевая модель

| Сейчас (модуль) | Станет |
|---|---|
| phoenix_kit_machine_types (+field_template) | Entity `machine_type`; записи EntityData; `field_template` — недекларируемый ключ в `data` (валидатор не трогает необъявленные ключи — проверено) |
| phoenix_kit_operations (name/unit/base_time_norm_seconds) | Entity `operation`: поля unit (select/text), base_time_norm_seconds (number); имя = title (+мультиязычность записей entities из коробки) |
| phoenix_kit_defect_reasons | Entity `defect_reason` (title+description) — тривиально |
| phoenix_kit_machines | ОСТАЁТСЯ схемой модуля (паспорт/места/файлы/ColumnConfig) |
| phoenix_kit_machine_type_assignments | остаётся; `machine_type_uuid` → мягкая ссылка на EntityData.uuid (FK снять) |
| phoenix_kit_machine_operations (+норма-override) | остаётся; `operation_uuid` → мягкая ссылка (FK снять); норма-override живёт здесь же — деградация мягкая при trash/удалении записи |

Ссылки — мягкие (без Postgres FK) + реакция на PubSub `PhoenixKitEntities.Events` (`{:data_deleted/updated, ...}`) по образцу StatusRegistry (ETS-кэш имён/лейблов с locale, инвалидация по событию). Модуль получает `pk_dep(:phoenix_kit_entities, "~> 0.2.7")` (Hex, форк не нужен).

## 2. Провижининг и перенос данных (миграция V5)

Рецепт 1:1 из `/www/app/priv/repo/migrations/20260502155927_seed_order_status_entities.exs`:
1. Идемпотентно ensure трёх Entity: `get_entity_by_name` → `create_entity` (+`set_entity_translation` en/et/ru для display_name); `created_by_uuid` передавать явно.
2. Перенос записей: для каждой строки трёх старых таблиц → `EntityData.create` (идемпотентность — existence-check по `data->>'legacy_uuid'`, куда кладём старый uuid); **конвертация мультиязычности**: наш формат `data[locale][field]` → формат entities `%{"_primary_language" => ..., locale => %{"_title" => ...}}`.
3. Перешивка ссылок: `machine_type_assignments.machine_type_uuid` и `machine_operations.operation_uuid` update по маппингу старый→новый uuid; DROP старых FK-констрейнтов.
4. DROP трёх старых таблиц.
5. **Редизайн version_probes (критично)**: probe_v3 сейчас ТРЕБУЕТ существования phoenix_kit_operations — после V5 она исчезает и вся probe-лестница ломается. Новая семантика: probe_vN проверяет структурное состояние «как после N» кумулятивно; для V5 — machines-колонки на месте,三 старых таблиц НЕТ, у join-таблиц НЕТ FK на них. Probe по отсутствию + отсутствию констрейнта. Отдельные тесты на «V4-хост апгрейдится до V5» и «свежий хост сразу V5».
6. Rollback V5 (down): пересоздать таблицы из данных entities не обязуемся — down = документированный no-op с raise (полный откат — restore из бэкапа); честно зафиксировать.

## 3. UI

- **Вариант A (рекомендую)**: подтабы модуля Types/Operations/Defect Reasons остаются, но ведут на штатные страницы entities `/admin/entities/:slug/data` (DataNavigator/DataForm — полный CRUD, поиск, статусы, translations бесплатно). Наши LiveView/формы этих справочников удаляются (−4 LiveView, −3 схемы, −3 контекста). Минус: generic-UX вместо нашего.
- Вариант B: тонкие module-LiveViews поверх EntityData API (сохранить наш UX/ColumnConfig) — дороже, дублирует то, что entities даёт даром. Оставить как возможный апгрейд.
- В карточке станка: бейджи типов и секция операций читают через новый тонкий контекст (`Machines.list_machine_types/0` → EntityData c `lang:`), пикеры — select по published-записям.
- reverse_references (конфиг andi): зарегистрировать счётчики «used by N machines» для operation/machine_type — advisory-подсказка в trash-UI entities.

## 4. Изменения кода модуля (объём)

Удаляются: schemas/{machine_type,operation,defect_reason}.ex, operations.ex, defect_reasons.ex, web/{machine_type_form,operation_form,defect_reason_form}_live.ex (+их тесты). Переписываются: machines.ex (sync_machine_types/sync_machine_operations — по мягким uuid; merged_field_template — чтение data["field_template"] записей entities; location_label не тронут), machine_form_live (пикеры), machines_live (подтабы→ссылки entities, удалить их списки), admin_tabs (пути), тест последнего таба, i18n. Новое: entities_registry.ex (ETS+PubSub, по StatusRegistry), конфиг reverse_references в andi.
Оценка: ~14-16 задач, сопоставимо с половиной волны v0.2.x.

## 5. Риски/компромиссы (принять осознанно)

1. **Целостность**: без FK возможны висячие ссылки при hard-delete записи (стандартный trade-off паттерна StatusRegistry; смягчение — trash вместо delete + reverse_references + graceful-деградация в UI).
2. **Уникальность имён/кодов** — теперь только app-side existence-check (в entities нет unique-опций полей).
3. **Валидации** ограничены типами entities (наши validate_format/inclusion для этих справочников уйдут в тонкий контекст, где критично).
4. **Права**: справочники окажутся под глобальным пермишеном "entities" (не manufacturing) — при Варианте A это видимое изменение модели доступа.
5. Полировка форм этих справочников из polish-волны (P3/P4 частично) станет одноразовой — осознанно.
6. Blueprint удалять нельзя (hard-cascade на все записи) — прикрыть только документацией/правами.
7. **Откат немыслим после V5**: `down/1` `Migrations.Machines` начиная с V5 безусловно `raise`ит (см. п.2.6 выше и moduledoc-секцию "## Rollback" в `migrations/machines.ex`) — `mix ecto.rollback` откатит модуль целиком (V1..V5), а не только дельту V5, поскольку `machine_type`/`operation`/`defect_reason` уже живут в отдельном пакете `phoenix_kit_entities`, чьи данные эта миграция не восстанавливает. Единственный поддерживаемый путь отката — restore БД из бэкапа, сделанного до V5. Осознанный компромисс, не баг.

## 6. Порядок

После завершения polish-волны: отдельная волна E1..E16 по этой спеке (план → ревью пары → реализация → миграционная контрольная точка → двойное финальное ревью). Upstream-PR: это ломающее изменение модели модуля — согласовать с мейнтейнером ДО реализации (его Machines v0.2 только что вышел; предложить как RFC/issue с этой спекой).
