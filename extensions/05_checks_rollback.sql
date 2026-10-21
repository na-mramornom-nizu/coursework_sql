                                                                               
                                                                       
BEGIN;
SET search_path TO pvz_lab, pg_temp;

DO $$
DECLARE v_id bigint; v_instance bigint; v_decision record;
BEGIN
    IF EXISTS (SELECT 1 FROM pvz_lab.validate_template('PICKUP_ORDER_V1')) THEN
        RAISE EXCEPTION 'Исходный шаблон не проходит проверку';
    END IF;
    IF (SELECT count(*) FROM v_template_transitions t
        JOIN process_template p ON p.template_id = t.template_id
        WHERE p.code = 'PICKUP_ORDER_V1') <> 7 THEN
        RAISE EXCEPTION 'Неверное число исходных переходов';
    END IF;

    PERFORM pvz_lab.save_pickup_point('PVZ-TEST', 'Учебный второй ПВЗ', 'Тестовый адрес');
    PERFORM pvz_lab.save_employee('OP_TEST', 'Тестовый оператор', 'PVZ-TEST');
    PERFORM pvz_lab.save_access_group('TEST_GROUP', 'Тестовая группа');
    PERFORM pvz_lab.set_employee_group('OP_TEST', 'TEST_GROUP', true);
    IF NOT EXISTS (SELECT 1 FROM employee_group eg
        JOIN employee e ON e.employee_id = eg.employee_id
        JOIN access_group g ON g.group_id = eg.group_id
        WHERE e.code = 'OP_TEST' AND g.code = 'TEST_GROUP') THEN
        RAISE EXCEPTION 'Группа не назначена сотруднику';
    END IF;
    PERFORM pvz_lab.set_employee_group('OP_TEST', 'TEST_GROUP', false);
    PERFORM pvz_lab.set_access_group_active('TEST_GROUP', false);
    PERFORM pvz_lab.set_access_group_active('TEST_GROUP', true);
    PERFORM pvz_lab.create_user_account('AD_01', 'test_admin', 'test-hash',
                                       ARRAY['CONSTRUCTOR','EXECUTOR']);
    PERFORM pvz_lab.update_user_account('test_admin', p_new_login => 'test_admin2');
    IF NOT EXISTS (SELECT 1 FROM user_account WHERE login = 'test_admin2') THEN
        RAISE EXCEPTION 'Логин не обновился';
    END IF;
    BEGIN
        PERFORM pvz_lab.update_user_account('test_admin2', p_is_active => false);
        RAISE EXCEPTION 'Отключение последнего конструктора принято';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'Отключение последнего конструктора принято' THEN RAISE; END IF;
    END;

    PERFORM pvz_lab.create_draft_template('ORDER_HANDLING', 'EMPTY_TEST', 'Пустой тест');
    PERFORM pvz_lab.add_template_state('EMPTY_TEST', 'START_TEST',
                                      'Тестовое начальное', true, false);
    PERFORM pvz_lab.delete_draft_state('EMPTY_TEST', 'START_TEST');
    BEGIN
        PERFORM pvz_lab.publish_template('EMPTY_TEST');
        RAISE EXCEPTION 'Пустой шаблон опубликован';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'Пустой шаблон опубликован' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM pvz_lab.add_template_state('PICKUP_ORDER_V1', 'ILLEGAL_TEST',
                                          'Запрещённое состояние');
        RAISE EXCEPTION 'Опубликованный шаблон изменён прямой функцией';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'Опубликованный шаблон изменён прямой функцией' THEN RAISE; END IF;
    END;

    v_id := pvz_lab.clone_template('PICKUP_ORDER_V1', 'PICKUP_ORDER_V2_TEST',
                                  'Тестовая версия 2');
    IF (SELECT count(*) FROM template_state WHERE template_id = v_id) <> 6
       OR (SELECT count(*) FROM v_template_transitions WHERE template_id = v_id) <> 7
       OR EXISTS (SELECT 1 FROM pvz_lab.validate_template('PICKUP_ORDER_V2_TEST')) THEN
        RAISE EXCEPTION 'Копия шаблона неполная';
    END IF;
    PERFORM pvz_lab.update_draft_template('PICKUP_ORDER_V2_TEST', 'Исправленная версия 2');
    PERFORM pvz_lab.update_draft_state('PICKUP_ORDER_V2_TEST', 'READY',
                                      'READY_TEST', 'Готов к выдаче', false, false);
    PERFORM pvz_lab.update_draft_state('PICKUP_ORDER_V2_TEST', 'READY_TEST',
                                      'READY', 'Готов к выдаче', false, false);
    PERFORM pvz_lab.save_draft_transition('PICKUP_ORDER_V2_TEST', 'ACCEPTED',
        'PLACE', 'Разместить на хранение', 'READY',
        p_replace_decision_code => 'PLACE');
    PERFORM pvz_lab.set_state_access('PICKUP_ORDER_V2_TEST', 'READY', 'ADMIN', true);
    PERFORM pvz_lab.set_decision_access('PICKUP_ORDER_V2_TEST', 'READY',
                                       'HAND_OVER', 'ADMIN', true);
    IF EXISTS (SELECT 1 FROM pvz_lab.validate_template('PICKUP_ORDER_V2_TEST')) THEN
        RAISE EXCEPTION 'Исправленный шаблон не проходит проверку';
    END IF;
    PERFORM pvz_lab.publish_template('PICKUP_ORDER_V2_TEST');
    IF (SELECT status FROM process_template WHERE code = 'PICKUP_ORDER_V1') <> 'ARCHIVED'
       OR (SELECT status FROM process_template WHERE code = 'PICKUP_ORDER_V2_TEST') <> 'PUBLISHED' THEN
        RAISE EXCEPTION 'Статусы версий после публикации неверны';
    END IF;
    BEGIN
        PERFORM pvz_lab.update_draft_template('PICKUP_ORDER_V2_TEST', 'Запрещено');
        RAISE EXCEPTION 'Опубликованный шаблон изменён';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'Опубликованный шаблон изменён' THEN RAISE; END IF;
    END;

    v_id := pvz_lab.create_order('TEST-ORDER-1', 'PVZ-01', 'OP_01',
        now(), now() + interval '5 days',
        '[{"sku":"A1","item_name":"Книга","quantity":2},
          {"sku":"A2","item_name":"Чехол","quantity":1}]'::jsonb);
    IF (SELECT count(*) FROM order_item WHERE order_id = v_id) <> 2 THEN
        RAISE EXCEPTION 'Товары заказа не записаны';
    END IF;
    PERFORM pvz_lab.update_order('TEST-ORDER-1', 'OP_01',
        now(), now() + interval '6 days',
        '[{"sku":"A3","item_name":"Новый товар","quantity":1}]'::jsonb);
    IF (SELECT count(*) FROM order_item WHERE order_id = v_id) <> 1 THEN
        RAISE EXCEPTION 'Изменение состава заказа не выполнено';
    END IF;
    BEGIN
        PERFORM pvz_lab.create_order('TEST-ORDER-CROSS', 'PVZ-TEST', 'OP_01',
            now(), now() + interval '1 day',
            '[{"sku":"X","item_name":"Товар","quantity":1}]'::jsonb);
        RAISE EXCEPTION 'Чужой ПВЗ принят';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'Чужой ПВЗ принят' THEN RAISE; END IF;
    END;
    IF EXISTS (SELECT 1 FROM pickup_order WHERE external_no = 'TEST-ORDER-CROSS') THEN
        RAISE EXCEPTION 'Неуспешный заказ оставил строку';
    END IF;
    v_instance := pvz_lab.start_process('TEST-ORDER-1', 'PICKUP_ORDER_V2_TEST', 'OP_01');
    SELECT * INTO v_decision FROM pvz_lab.list_available_decisions(v_instance, 'OP_01')
    WHERE decision_code = 'ACCEPT';
    IF v_decision.is_allowed OR v_decision.reason <> 'FALSE_GUARD' THEN
        RAISE EXCEPTION 'Неизвестное повреждение не блокирует приёмку';
    END IF;
    PERFORM pvz_lab.record_inspection('TEST-ORDER-1', 'OP_01', false);
    SELECT * INTO v_decision FROM pvz_lab.list_available_decisions(v_instance, 'OP_01')
    WHERE decision_code = 'ACCEPT';
    IF NOT v_decision.is_allowed THEN RAISE EXCEPTION 'Приёмка после осмотра недоступна'; END IF;
    PERFORM pvz_lab.apply_decision(v_instance, 'ACCEPT', 'OP_01');
    IF (SELECT count(*) FROM pvz_lab.read_trajectory(v_instance)) <> 2 THEN
        RAISE EXCEPTION 'Исходное чтение траектории нарушено';
    END IF;
    BEGIN
        PERFORM pvz_lab.record_inspection('TEST-ORDER-1', 'OP_01', true);
        RAISE EXCEPTION 'Осмотр изменён после решения';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'Осмотр изменён после решения' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM pvz_lab.update_order('TEST-ORDER-1', 'OP_01',
            now(), now() + interval '7 days',
            '[{"sku":"A4","item_name":"Ошибка","quantity":1}]'::jsonb);
        RAISE EXCEPTION 'Заказ изменён после запуска';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'Заказ изменён после запуска' THEN RAISE; END IF;
    END;
    PERFORM pvz_lab.set_employee_active('OP_01', false);
    BEGIN
        PERFORM pvz_lab.start_process('PVZ-ORDER-004',
            'PICKUP_ORDER_V2_TEST', 'OP_01');
        RAISE EXCEPTION 'Отключённый сотрудник запустил процесс';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'Отключённый сотрудник запустил процесс' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM pvz_lab.set_pickup_point_active('PVZ-01', false);
        RAISE EXCEPTION 'Отключён ПВЗ последнего конструктора';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'Отключён ПВЗ последнего конструктора' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'PASS: справочники, роли, шаблоны, заказ, осмотр и решения';
END;
$$;
ROLLBACK;
