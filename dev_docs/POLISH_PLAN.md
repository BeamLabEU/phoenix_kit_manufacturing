# Polish-волна UI/i18n (2026-07-11, по фидбеку владельца)

Рецепты и file:line — исследование стандартов 2026-07-11. Стандарты: сайдбар-переводы через Tab.gettext_backend; заголовок+подзаголовок каждого окна — в глобальном хеддере (LayoutWrapper.app_layout page_title/page_subtitle, self-wrap on_mount), в теле страницы НЕ дублируем; формы — max-w-none (не узкая колонка); карточка станка — вкладки in-page (tabs tabs-border + patch, как internal_order_form_live.ex:886).

### P1. Переводы сайдбара
phoenix_kit_manufacturing.ex admin_tabs/0: КАЖДОМУ %Tab{} добавить gettext_backend: PhoenixKitManufacturing.Gettext, gettext_domain: "default" (образец: phoenix_kit_warehouse.ex:60-72). mix gettext.extract+merge, et/ru msgstr для всех label (Manufacturing/Производство/Tootmine, Machines/Станки/Masinad, Types/Типы/Tüübid, Operations/Операции/Toimingud, Defect Reasons/Причины брака/Defektide põhjused, Dashboard и скрытые).
Проверка: mix test (тесты табов), рестарт-контроль оркестратора.

### P2. Хеддер: список
machines_live.ex → self-wrap паттерн (on_mount :self_wrapped_layout + LayoutWrapper.app_layout, образец stock_live.ex:27-62,518-533): page_title = активный подтаб (Machines/Types/Operations/Defect Reasons), page_subtitle = краткое описание раздела; убрать in-page <.admin_page_header> (:482). Переключатель разделов оставить как локальный tab-бар под хеддером (как WarehouseHeader).

### P3. Хеддер: формы
machine_form_live.ex, machine_type_form_live.ex, operation_form_live.ex, defect_reason_form_live.ex → тот же self-wrap паттерн: page_title («New machine»/имя станка), page_subtitle (код/тип или назначение раздела) в глобальный хеддер; in-page admin_page_header убрать. (Осознанное решение владельца: «заголовок каждого окна в хеддере, больше не отображаем» — идём дальше текущего складского кода форм.)

### P4. Ширина форм
machine_form_live.ex:508 max-w-3xl mx-auto → max-w-none (образец internal_order_form_live.ex:822 "flex flex-col mx-auto max-w-none sm:px-4 py-2 sm:py-6 gap-4"); паспорт — сетка до lg:grid-cols-3. Те же right-size правки для operation/defect_reason/machine_type форм (max-w-none + разумная сетка).

### P5. Вкладки карточки станка
По складскому паттерну (та же LiveView, patch): hidden CRUD tab-роуты /machines/:uuid/{operations,files,comments} (visible:false, как warehouse hidden_crud_tabs) + in-page tabs tabs-border бар. Вкладки: General (паспорт+место+типы+спец-поля шаблона), Operations (перенести секцию), Files (фото+файлы), Comments (перенести). Обновить тест «последний таб». :new остаётся одностраничным General (без вкладок до сохранения, как в складе).

### P6. Полная библиотека для заглавного фото
Featured-image пикер станка открывать с scope_folder_id: nil (полная медиа-библиотека, поддерживается MediaSelectorModal по докам :66-76); прикреплённые файлы — папочный скоуп как был. Комментарий-обоснование в коде.

### P7. Добить переводы
mix gettext.extract+merge; заполнить ВСЕ пустые msgstr: et (~130) и ru (~92) + новые строки волны; en — msgstr пустые/=msgid; аудит fuzzy-повреждений по всем трём локалям (известная проблема).

### P8. Финализация
mix format/compile --warnings-as-errors/test; актуализация moduledoc'ов затронутых LiveView; коммиты по задачам.

Ограничения: PHOENIX_KIT_LOCATIONS_PATH=../phoenix_kit_locations для всех mix-команд; рестарты/живая проверка — оркестратор; CHANGELOG/@version не трогать.
