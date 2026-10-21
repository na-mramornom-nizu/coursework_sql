                                                                                 
                                             
BEGIN;
SET search_path TO pvz_lab, pg_temp;

CREATE OR REPLACE FUNCTION pvz_lab.require_active_employee_at_point(
    p_employee_code text, p_point_id bigint
) RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_employee_id bigint;
BEGIN
    SELECT e.employee_id INTO v_employee_id
    FROM employee e JOIN pickup_point p ON p.point_id = e.point_id
    WHERE e.code = p_employee_code AND e.point_id = p_point_id
      AND e.is_active AND p.is_active;
    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Действующий сотрудник % не закреплён за действующим ПВЗ заказа',
            p_employee_code;
    END IF;
    RETURN v_employee_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.replace_order_items(
    p_order_id bigint, p_items jsonb
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_item jsonb; v_sku text; v_name text; v_quantity integer;
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
       OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'Заказ должен содержать непустой список товаров';
    END IF;
    DELETE FROM order_item WHERE order_id = p_order_id;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
        IF jsonb_typeof(v_item) <> 'object' THEN
            RAISE EXCEPTION 'Каждая позиция должна быть объектом JSON';
        END IF;
        v_sku := nullif(btrim(v_item ->> 'sku'), '');
        v_name := nullif(btrim(v_item ->> 'item_name'), '');
        IF v_sku IS NULL OR v_name IS NULL OR (v_item ->> 'quantity') IS NULL THEN
            RAISE EXCEPTION 'Позиции нужны sku, item_name и quantity';
        END IF;
        v_quantity := (v_item ->> 'quantity')::integer;
        IF v_quantity <= 0 THEN RAISE EXCEPTION 'Количество должно быть положительным'; END IF;
        INSERT INTO order_item(order_id, sku, item_name, quantity)
        VALUES (p_order_id, v_sku, v_name, v_quantity);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.create_order(
    p_external_no text, p_point_code text, p_employee_code text,
    p_expected_at timestamptz, p_storage_until timestamptz, p_items jsonb
) RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_point_id bigint; v_order_id bigint;
BEGIN
    IF nullif(btrim(p_external_no), '') IS NULL THEN
        RAISE EXCEPTION 'Номер заказа обязателен';
    END IF;
    SELECT point_id INTO v_point_id FROM pickup_point
    WHERE code = p_point_code AND is_active;
    IF v_point_id IS NULL THEN RAISE EXCEPTION 'Действующий ПВЗ % не найден', p_point_code; END IF;
    PERFORM pvz_lab.require_active_employee_at_point(p_employee_code, v_point_id);
    INSERT INTO pickup_order(external_no, point_id, expected_at, storage_until)
    VALUES (btrim(p_external_no), v_point_id, p_expected_at, p_storage_until)
    RETURNING order_id INTO v_order_id;
    PERFORM pvz_lab.replace_order_items(v_order_id, p_items);
    RETURN v_order_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.update_order(
    p_external_no text, p_employee_code text,
    p_expected_at timestamptz, p_storage_until timestamptz, p_items jsonb
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_order_id bigint; v_point_id bigint;
BEGIN
    SELECT order_id, point_id INTO v_order_id, v_point_id
    FROM pickup_order WHERE external_no = p_external_no FOR UPDATE;
    IF v_order_id IS NULL THEN RAISE EXCEPTION 'Заказ % не найден', p_external_no; END IF;
    PERFORM pvz_lab.require_active_employee_at_point(p_employee_code, v_point_id);
    IF EXISTS (SELECT 1 FROM process_instance WHERE order_id = v_order_id) THEN
        RAISE EXCEPTION 'Заказ с запущенным процессом изменять нельзя';
    END IF;
    UPDATE pickup_order SET expected_at = p_expected_at,
        storage_until = p_storage_until WHERE order_id = v_order_id;
    PERFORM pvz_lab.replace_order_items(v_order_id, p_items);
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.record_inspection(
    p_external_no text, p_employee_code text, p_is_damaged boolean
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_order_id bigint; v_point_id bigint;
BEGIN
    IF p_is_damaged IS NULL THEN RAISE EXCEPTION 'Укажите результат осмотра'; END IF;
    SELECT order_id, point_id INTO v_order_id, v_point_id
    FROM pickup_order WHERE external_no = p_external_no FOR UPDATE;
    IF v_order_id IS NULL THEN RAISE EXCEPTION 'Заказ % не найден', p_external_no; END IF;
    PERFORM pvz_lab.require_active_employee_at_point(p_employee_code, v_point_id);
    IF EXISTS (
        SELECT 1 FROM process_instance pi
        WHERE pi.order_id = v_order_id AND (
            pi.finished_at IS NOT NULL OR EXISTS (
                SELECT 1 FROM process_trajectory tr
                WHERE tr.instance_id = pi.instance_id AND tr.position_no > 1
            )
        )
    ) THEN RAISE EXCEPTION 'После первого решения результат осмотра менять нельзя'; END IF;
    UPDATE pickup_order SET is_damaged = p_is_damaged WHERE order_id = v_order_id;
END;
$$;

                                                                     
                                                                       
CREATE OR REPLACE FUNCTION pvz_lab.ensure_execution_actor_active()
RETURNS trigger LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_employee_id bigint; v_point_id bigint;
BEGIN
    IF TG_TABLE_NAME = 'process_instance' THEN
        v_employee_id := NEW.started_by;
        SELECT point_id INTO v_point_id FROM pickup_order WHERE order_id = NEW.order_id;
    ELSE
        v_employee_id := NEW.entered_by;
        SELECT o.point_id INTO v_point_id FROM process_instance pi
        JOIN pickup_order o ON o.order_id = pi.order_id
        WHERE pi.instance_id = NEW.instance_id;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM employee e JOIN pickup_point p ON p.point_id = e.point_id
        WHERE e.employee_id = v_employee_id AND e.point_id = v_point_id
          AND e.is_active AND p.is_active
    ) THEN RAISE EXCEPTION 'Недействующий сотрудник или ПВЗ: действие отклонено'; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER coursework_active_actor_instance
    BEFORE INSERT ON process_instance FOR EACH ROW
    EXECUTE FUNCTION pvz_lab.ensure_execution_actor_active();
CREATE TRIGGER coursework_active_actor_trajectory
    BEFORE INSERT ON process_trajectory FOR EACH ROW
    EXECUTE FUNCTION pvz_lab.ensure_execution_actor_active();

CREATE OR REPLACE FUNCTION pvz_lab.list_available_decisions(
    p_instance_id bigint, p_employee_code text
) RETURNS TABLE(decision_code text, decision_name text, target_state_code text,
                is_allowed boolean, reason text)
LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_instance process_instance%ROWTYPE; v_state_id bigint;
        v_employee_id bigint; v_point_id bigint;
        v_damaged boolean; v_storage_until timestamptz;
BEGIN
    SELECT * INTO v_instance FROM process_instance WHERE instance_id = p_instance_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Экземпляр процесса % не найден', p_instance_id; END IF;
    SELECT point_id, is_damaged, storage_until
    INTO v_point_id, v_damaged, v_storage_until
    FROM pickup_order WHERE order_id = v_instance.order_id;
    v_employee_id := pvz_lab.require_active_employee_at_point(p_employee_code, v_point_id);
    IF v_instance.finished_at IS NOT NULL THEN RETURN; END IF;
    SELECT tr.state_id INTO v_state_id FROM process_trajectory tr
    WHERE tr.instance_id = p_instance_id ORDER BY tr.position_no DESC LIMIT 1;
    RETURN QUERY
    SELECT dt.code, dt.name, t.target_code,
           (permitted.can_use AND guarded.passes),
           CASE WHEN NOT permitted.can_use THEN 'NO_ACCESS'
                WHEN NOT guarded.passes THEN 'FALSE_GUARD'
                ELSE 'AVAILABLE' END
    FROM v_template_transitions t
    JOIN decision_type dt ON dt.decision_id = t.decision_id
    CROSS JOIN LATERAL (
        SELECT EXISTS (
            SELECT 1 FROM employee_group eg
            JOIN state_access sa ON sa.group_id = eg.group_id
            WHERE eg.employee_id = v_employee_id AND sa.state_id = v_state_id
        ) AND EXISTS (
            SELECT 1 FROM employee_group eg
            JOIN decision_access da ON da.group_id = eg.group_id
            WHERE eg.employee_id = v_employee_id AND da.state_id = v_state_id
              AND da.decision_id = t.decision_id
        ) AS can_use
    ) permitted
    CROSS JOIN LATERAL (
        SELECT CASE t.condition_kind
            WHEN 'ORDER_DAMAGED' THEN
                v_damaged IS NOT NULL AND v_damaged = t.expected_bool
            WHEN 'STORAGE_EXPIRED' THEN
                (clock_timestamp() >= v_storage_until) = t.expected_bool
            ELSE true END AS passes
    ) guarded
    WHERE t.template_id = v_instance.template_id AND t.source_state_id = v_state_id
    ORDER BY dt.code;
END;
$$;

COMMIT;
