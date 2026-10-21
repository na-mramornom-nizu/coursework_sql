# Coursework SQL

SQL-скрипты учебного приложения для управления обработкой заказов в ПВЗ. Исходная модель задания 3-1-1 сохранена в файлах `01_schema.sql`, `02_functions.sql`, `03_seed.sql`. Скрипты курсовой находятся в каталоге `extensions/`. Комментарии из публикуемых листингов удалены; исходные файлы защищённой лабораторной работы не изменены.

Порядок создания новой базы `coursework_pvz`:

1. `01_schema.sql`
2. `02_functions.sql`
3. `03_seed.sql`
4. `extensions/01_coursework_schema.sql`
5. `extensions/02_people_and_access.sql`
6. `extensions/03_template_lifecycle.sql`
7. `extensions/04_orders_and_execution.sql`
8. `extensions/06_order_number_edit.sql`
9. `extensions/05_checks_rollback.sql` — контроль с откатом изменений.
10. `extensions/07_extra_demo_orders.sql` — дополнительные учебные заказы.

`extensions/verify_baseline.sql` содержит проверочные выборки и не изменяет данные. Порядок можно выполнить автоматически скриптом `setup_from_scratch.ps1` из репозитория `coursework_backend`.
