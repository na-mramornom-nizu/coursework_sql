                                                                                

CREATE OR REPLACE FUNCTION pvz_lab.create_process_type(
    p_code text, p_name text, p_parent_code text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE
    v_parent_id bigint;
    v_type_id bigint;
BEGIN
    IF p_parent_code IS NOT NULL THEN
        SELECT type_id INTO v_parent_id FROM process_type WHERE code = p_parent_code;
        IF v_parent_id IS NULL THEN
            RAISE EXCEPTION 'Не найден родительский тип процесса: %', p_parent_code;
        END IF;
    END IF;
    INSERT INTO process_type(code, name, parent_type_id)
    VALUES (p_code, p_name, v_parent_id)
    RETURNING type_id INTO v_type_id;
    RETURN v_type_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.create_process_template(
    p_type_code text, p_code text, p_name text
) RETURNS bigint
LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE
    v_type_id bigint;
    v_template_id bigint;
BEGIN
    SELECT type_id INTO v_type_id FROM process_type WHERE code = p_type_code;
    IF v_type_id IS NULL THEN
        RAISE EXCEPTION 'Не найден тип процесса: %', p_type_code;
    END IF;
    INSERT INTO process_template(type_id, code, name)
    VALUES (v_type_id, p_code, p_name)
    RETURNING template_id INTO v_template_id;
    RETURN v_template_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.add_template_state(
    p_template_code text, p_state_code text, p_name text,
    p_is_initial boolean DEFAULT false, p_is_terminal boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE
    v_template_id bigint;
    v_state_id bigint;
BEGIN
    SELECT template_id INTO v_template_id
    FROM process_template WHERE code = p_template_code;
    IF v_template_id IS NULL THEN
        RAISE EXCEPTION 'Не найден шаблон процесса: %', p_template_code;
    END IF;
    INSERT INTO template_state(template_id, code, name, is_initial, is_terminal)
    VALUES (v_template_id, p_state_code, p_name, p_is_initial, p_is_terminal)
    RETURNING state_id INTO v_state_id;
    RETURN v_state_id;
END;
$$;

                                                                                  
                                                                        
CREATE OR REPLACE FUNCTION pvz_lab.add_transition(
    p_template_code text,
    p_from_code text,
    p_decision_code text,
    p_decision_name text,
    p_to_code text,
    p_condition_kind text DEFAULT NULL,
    p_expected_bool boolean DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE
    v_template_id bigint;
    v_from_id bigint;
    v_to_id bigint;
    v_from_terminal boolean;
    v_to_initial boolean;
    v_decision_id bigint;
    v_clause_id bigint;
    v_clause_no integer;
    v_predicate_id bigint;
BEGIN
    SELECT template_id INTO v_template_id
    FROM process_template WHERE code = p_template_code;
    IF v_template_id IS NULL THEN
        RAISE EXCEPTION 'Не найден шаблон: %', p_template_code;
    END IF;
    SELECT state_id, is_terminal INTO v_from_id, v_from_terminal
    FROM template_state
    WHERE template_id = v_template_id AND code = p_from_code;
    SELECT state_id, is_initial INTO v_to_id, v_to_initial
    FROM template_state
    WHERE template_id = v_template_id AND code = p_to_code;
    IF v_from_id IS NULL OR v_to_id IS NULL THEN
        RAISE EXCEPTION 'Не найдено исходное или целевое состояние: % -> %',
            p_from_code, p_to_code;
    END IF;
    IF v_from_terminal OR v_to_initial THEN
        RAISE EXCEPTION 'Переход из конечного состояния или в начальное состояние недопустим';
    END IF;
    IF (p_condition_kind IS NULL) <> (p_expected_bool IS NULL) THEN
        RAISE EXCEPTION 'Для дополнительного предиката нужны его тип и ожидаемое значение';
    END IF;
    IF p_condition_kind IS NOT NULL
       AND p_condition_kind NOT IN ('ORDER_DAMAGED', 'STORAGE_EXPIRED') THEN
        RAISE EXCEPTION 'Неизвестный дополнительный предикат: %', p_condition_kind;
    END IF;

    INSERT INTO decision_type(code, name)
    VALUES (p_decision_code, p_decision_name)
    ON CONFLICT (code) DO NOTHING;
    SELECT decision_id INTO v_decision_id
    FROM decision_type WHERE code = p_decision_code;
    IF EXISTS (
        SELECT 1 FROM state_decision
        WHERE state_id = v_from_id AND decision_id = v_decision_id
    ) THEN
        RAISE EXCEPTION 'Решение % уже задано для состояния %',
            p_decision_code, p_from_code;
    END IF;
    INSERT INTO state_decision(state_id, decision_id)
    VALUES (v_from_id, v_decision_id);

    SELECT COALESCE(MAX(clause_no), 0) + 1 INTO v_clause_no
    FROM guard_clause WHERE target_state_id = v_to_id;
    INSERT INTO guard_clause(template_id, target_state_id, clause_no)
    VALUES (v_template_id, v_to_id, v_clause_no)
    RETURNING clause_id INTO v_clause_id;

    INSERT INTO guard_predicate(template_id, kind, state_id)
    VALUES (v_template_id, 'STATE_IS', v_from_id)
    RETURNING predicate_id INTO v_predicate_id;
    INSERT INTO guard_clause_predicate(template_id, clause_id, predicate_id, position_no)
    VALUES (v_template_id, v_clause_id, v_predicate_id, 1);

    INSERT INTO guard_predicate(template_id, kind, decision_id)
    VALUES (v_template_id, 'DECISION_IS', v_decision_id)
    RETURNING predicate_id INTO v_predicate_id;
    INSERT INTO guard_clause_predicate(template_id, clause_id, predicate_id, position_no)
    VALUES (v_template_id, v_clause_id, v_predicate_id, 2);

    IF p_condition_kind IS NOT NULL THEN
        INSERT INTO guard_predicate(template_id, kind, expected_bool)
        VALUES (v_template_id, p_condition_kind, p_expected_bool)
        RETURNING predicate_id INTO v_predicate_id;
        INSERT INTO guard_clause_predicate(template_id, clause_id, predicate_id, position_no)
        VALUES (v_template_id, v_clause_id, v_predicate_id, 3);
    END IF;
    RETURN v_clause_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.start_process(
    p_order_no text, p_template_code text, p_employee_code text
) RETURNS bigint
LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE
    v_order_id bigint;
    v_order_point_id bigint;
    v_template_id bigint;
    v_initial_state_id bigint;
    v_employee_id bigint;
    v_employee_point_id bigint;
    v_instance_id bigint;
BEGIN
    SELECT order_id, point_id INTO v_order_id, v_order_point_id
    FROM pickup_order WHERE external_no = p_order_no;
    SELECT template_id INTO v_template_id
    FROM process_template WHERE code = p_template_code AND is_active;
    SELECT employee_id, point_id INTO v_employee_id, v_employee_point_id
    FROM employee WHERE code = p_employee_code;
    IF v_order_id IS NULL OR v_template_id IS NULL OR v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Не найден заказ, активный шаблон или сотрудник';
    END IF;
    IF v_employee_point_id <> v_order_point_id THEN
        RAISE EXCEPTION 'Сотрудник % не закреплён за ПВЗ заказа %',
            p_employee_code, p_order_no;
    END IF;
    SELECT state_id INTO v_initial_state_id
    FROM template_state WHERE template_id = v_template_id AND is_initial;
    IF v_initial_state_id IS NULL THEN
        RAISE EXCEPTION 'У шаблона % нет начального состояния', p_template_code;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM employee_group eg
        JOIN state_access sa ON sa.group_id = eg.group_id
        WHERE eg.employee_id = v_employee_id AND sa.state_id = v_initial_state_id
    ) THEN
        RAISE EXCEPTION 'Сотрудник % не имеет доступа к запуску процесса',
            p_employee_code;
    END IF;
    INSERT INTO process_instance(template_id, order_id, started_by)
    VALUES (v_template_id, v_order_id, v_employee_id)
    RETURNING instance_id INTO v_instance_id;
    INSERT INTO process_trajectory(
        instance_id, template_id, position_no, state_id, entered_by, note
    ) VALUES (
        v_instance_id, v_template_id, 1, v_initial_state_id,
        v_employee_id, 'Создан экземпляр процесса'
    );
    RETURN v_instance_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.apply_decision(
    p_instance_id bigint, p_decision_code text,
    p_employee_code text, p_note text DEFAULT NULL
) RETURNS TABLE(out_position integer, out_state_code text,
                out_state_name text, out_is_terminal boolean)
LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE
    v_instance process_instance%ROWTYPE;
    v_current_state_id bigint;
    v_current_position integer;
    v_decision_id bigint;
    v_employee_id bigint;
    v_employee_point_id bigint;
    v_order_point_id bigint;
    v_is_damaged boolean;
    v_storage_until timestamptz;
    v_match_count integer;
    v_next_state_id bigint;
    v_next_code text;
    v_next_name text;
    v_next_terminal boolean;
BEGIN
    SELECT * INTO v_instance
    FROM process_instance WHERE instance_id = p_instance_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Экземпляр процесса % не найден', p_instance_id;
    END IF;
    IF v_instance.finished_at IS NOT NULL THEN
        RAISE EXCEPTION 'Процесс % уже завершен', p_instance_id;
    END IF;
    SELECT state_id, position_no INTO v_current_state_id, v_current_position
    FROM process_trajectory
    WHERE instance_id = p_instance_id
    ORDER BY position_no DESC LIMIT 1;
    SELECT decision_id INTO v_decision_id
    FROM decision_type WHERE code = p_decision_code;
    SELECT employee_id, point_id INTO v_employee_id, v_employee_point_id
    FROM employee WHERE code = p_employee_code;
    IF v_decision_id IS NULL OR v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Не найдено решение % или сотрудник %',
            p_decision_code, p_employee_code;
    END IF;
    SELECT point_id INTO v_order_point_id
    FROM pickup_order WHERE order_id = v_instance.order_id;
    IF v_employee_point_id <> v_order_point_id THEN
        RAISE EXCEPTION 'Сотрудник % не закреплён за ПВЗ этого заказа',
            p_employee_code;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM state_access sa
        JOIN employee_group eg ON eg.group_id = sa.group_id
        WHERE sa.state_id = v_current_state_id AND eg.employee_id = v_employee_id
    ) THEN
        RAISE EXCEPTION 'Сотрудник % не имеет доступа к текущему состоянию',
            p_employee_code;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM state_decision
        WHERE state_id = v_current_state_id AND decision_id = v_decision_id
    ) THEN
        RAISE EXCEPTION 'Решение % недопустимо в текущем состоянии',
            p_decision_code;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM decision_access da
        JOIN employee_group eg ON eg.group_id = da.group_id
        WHERE da.state_id = v_current_state_id
          AND da.decision_id = v_decision_id
          AND eg.employee_id = v_employee_id
    ) THEN
        RAISE EXCEPTION 'Сотрудник % не имеет доступа к решению %',
            p_employee_code, p_decision_code;
    END IF;
    SELECT is_damaged, storage_until INTO v_is_damaged, v_storage_until
    FROM pickup_order WHERE order_id = v_instance.order_id;

    WITH eligible AS (
        SELECT DISTINCT gc.target_state_id
        FROM guard_clause gc
        WHERE gc.template_id = v_instance.template_id
          AND NOT EXISTS (
              SELECT 1
              FROM guard_clause_predicate gcp
              JOIN guard_predicate gp ON gp.predicate_id = gcp.predicate_id
              WHERE gcp.clause_id = gc.clause_id
                AND NOT (CASE gp.kind
                    WHEN 'STATE_IS' THEN gp.state_id = v_current_state_id
                    WHEN 'DECISION_IS' THEN gp.decision_id = v_decision_id
                    WHEN 'ORDER_DAMAGED' THEN
                        v_is_damaged IS NOT NULL
                        AND v_is_damaged = gp.expected_bool
                    WHEN 'STORAGE_EXPIRED' THEN
                        (clock_timestamp() >= v_storage_until) = gp.expected_bool
                    ELSE false
                END)
          )
    )
    SELECT count(*)::integer, min(target_state_id)
    INTO v_match_count, v_next_state_id FROM eligible;
    IF v_match_count = 0 THEN
        RAISE EXCEPTION 'Сторожевое условие перехода для решения % ложно',
            p_decision_code;
    END IF;
    IF v_match_count > 1 THEN
        RAISE EXCEPTION 'Для решения % найдено несколько следующих состояний',
            p_decision_code;
    END IF;

    SELECT code, name, is_terminal
    INTO v_next_code, v_next_name, v_next_terminal
    FROM template_state WHERE state_id = v_next_state_id;
    INSERT INTO process_trajectory(
        instance_id, template_id, position_no, state_id,
        decision_id, entered_by, note
    ) VALUES (
        p_instance_id, v_instance.template_id, v_current_position + 1,
        v_next_state_id, v_decision_id, v_employee_id, p_note
    );
    IF v_next_terminal THEN
        UPDATE process_instance SET finished_at = clock_timestamp()
        WHERE instance_id = p_instance_id;
    END IF;
    RETURN QUERY SELECT v_current_position + 1, v_next_code,
                        v_next_name, v_next_terminal;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.read_trajectory(p_instance_id bigint)
RETURNS TABLE(position_no integer, state_name text, decision_name text,
              employee_name text, entered_at timestamptz, note text)
LANGUAGE sql SET search_path = pvz_lab, pg_temp AS $$
    SELECT tr.position_no, ts.name, dt.name, e.full_name,
           tr.entered_at, tr.note
    FROM process_trajectory tr
    JOIN template_state ts ON ts.state_id = tr.state_id
    LEFT JOIN decision_type dt ON dt.decision_id = tr.decision_id
    JOIN employee e ON e.employee_id = tr.entered_by
    WHERE tr.instance_id = p_instance_id
    ORDER BY tr.position_no;
$$;
