                                                                                     
BEGIN;
SET search_path TO pvz_lab, pg_temp;

CREATE OR REPLACE FUNCTION pvz_lab.require_draft(p_template_code text)
RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
    SELECT template_id INTO v_id FROM process_template
    WHERE code = p_template_code AND status = 'DRAFT' FOR UPDATE;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'Черновик шаблона % не найден или уже опубликован', p_template_code;
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.save_pickup_point(
    p_code text, p_name text, p_address text DEFAULT NULL
) RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
    IF nullif(btrim(p_code), '') IS NULL OR nullif(btrim(p_name), '') IS NULL THEN
        RAISE EXCEPTION 'Код и название ПВЗ обязательны';
    END IF;
    INSERT INTO pickup_point(code, name, address)
    VALUES (btrim(p_code), btrim(p_name), nullif(btrim(p_address), ''))
    ON CONFLICT (code) DO UPDATE
      SET name = EXCLUDED.name, address = EXCLUDED.address
    RETURNING point_id INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.set_pickup_point_active(p_code text, p_active boolean)
RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_point_id bigint;
BEGIN
    IF p_active IS NULL THEN RAISE EXCEPTION 'Признак активности ПВЗ обязателен'; END IF;
    UPDATE pickup_point SET is_active = p_active WHERE code = p_code
    RETURNING point_id INTO v_point_id;
    IF v_point_id IS NULL THEN RAISE EXCEPTION 'ПВЗ % не найден', p_code; END IF;
    IF NOT p_active THEN
        UPDATE user_account a SET session_version = session_version + 1
        FROM employee e WHERE a.employee_id = e.employee_id
          AND e.point_id = v_point_id;
        IF EXISTS (SELECT 1 FROM user_account_role WHERE role_code = 'CONSTRUCTOR')
           AND NOT EXISTS (
               SELECT 1 FROM user_account a
               JOIN user_account_role r ON r.account_id = a.account_id
               JOIN employee e ON e.employee_id = a.employee_id
               JOIN pickup_point p ON p.point_id = e.point_id
               WHERE a.is_active AND e.is_active AND p.is_active
                 AND r.role_code = 'CONSTRUCTOR'
           ) THEN RAISE EXCEPTION 'Нельзя отключить ПВЗ последнего конструктора'; END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.save_employee(
    p_code text, p_full_name text, p_point_code text
) RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_id bigint; v_point_id bigint; v_old_point_id bigint;
BEGIN
    IF nullif(btrim(p_code), '') IS NULL OR nullif(btrim(p_full_name), '') IS NULL THEN
        RAISE EXCEPTION 'Код и имя сотрудника обязательны';
    END IF;
    SELECT point_id INTO v_point_id FROM pickup_point
    WHERE code = p_point_code AND is_active;
    IF v_point_id IS NULL THEN RAISE EXCEPTION 'Действующий ПВЗ % не найден', p_point_code; END IF;
    SELECT point_id INTO v_old_point_id FROM employee WHERE code = btrim(p_code);
    INSERT INTO employee(code, full_name, point_id)
    VALUES (btrim(p_code), btrim(p_full_name), v_point_id)
    ON CONFLICT (code) DO UPDATE
      SET full_name = EXCLUDED.full_name, point_id = EXCLUDED.point_id
    RETURNING employee_id INTO v_id;
    IF v_old_point_id IS DISTINCT FROM v_point_id THEN
        UPDATE user_account SET session_version = session_version + 1
        WHERE employee_id = v_id;
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.set_employee_active(p_code text, p_active boolean)
RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
    IF p_active IS NULL THEN RAISE EXCEPTION 'Признак активности сотрудника обязателен'; END IF;
    UPDATE employee SET is_active = p_active WHERE code = p_code
    RETURNING employee_id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Сотрудник % не найден', p_code; END IF;
    IF NOT p_active THEN
        UPDATE user_account SET session_version = session_version + 1
        WHERE employee_id = v_id;
        IF NOT EXISTS (
            SELECT 1 FROM user_account a
            JOIN user_account_role r ON r.account_id = a.account_id
            JOIN employee e ON e.employee_id = a.employee_id
            JOIN pickup_point p ON p.point_id = e.point_id
            WHERE a.is_active AND e.is_active AND p.is_active
              AND r.role_code = 'CONSTRUCTOR'
        ) AND EXISTS (SELECT 1 FROM user_account_role WHERE role_code = 'CONSTRUCTOR') THEN
            RAISE EXCEPTION 'Нельзя отключить последнего действующего конструктора';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.create_user_account(
    p_employee_code text, p_login text, p_password_hash text, p_roles text[]
) RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_employee_id bigint; v_account_id bigint;
BEGIN
    IF nullif(btrim(p_login), '') IS NULL OR nullif(btrim(p_password_hash), '') IS NULL THEN
        RAISE EXCEPTION 'Логин и хеш пароля обязательны';
    END IF;
    IF p_roles IS NULL OR cardinality(p_roles) = 0 OR EXISTS (
        SELECT 1 FROM unnest(p_roles) AS r(role_code)
        WHERE role_code IS NULL OR role_code NOT IN ('CONSTRUCTOR', 'EXECUTOR')
    ) THEN RAISE EXCEPTION 'Укажите хотя бы одну допустимую роль'; END IF;
    SELECT e.employee_id INTO v_employee_id FROM employee e
    WHERE e.code = p_employee_code AND e.is_active;
    IF v_employee_id IS NULL THEN RAISE EXCEPTION 'Действующий сотрудник % не найден', p_employee_code; END IF;
    INSERT INTO user_account(employee_id, login, password_hash)
    VALUES (v_employee_id, btrim(p_login), p_password_hash)
    RETURNING account_id INTO v_account_id;
    INSERT INTO user_account_role(account_id, role_code)
    SELECT v_account_id, r FROM (SELECT DISTINCT unnest(p_roles) AS r) q;
    RETURN v_account_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.update_user_account(
    p_login text, p_new_login text DEFAULT NULL, p_password_hash text DEFAULT NULL,
    p_roles text[] DEFAULT NULL, p_is_active boolean DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_account_id bigint;
BEGIN
    SELECT account_id INTO v_account_id FROM user_account
    WHERE lower(login) = lower(p_login) FOR UPDATE;
    IF v_account_id IS NULL THEN RAISE EXCEPTION 'Учётная запись % не найдена', p_login; END IF;
    IF p_new_login IS NOT NULL AND nullif(btrim(p_new_login), '') IS NULL THEN
        RAISE EXCEPTION 'Логин не может быть пустым';
    END IF;
    IF p_password_hash IS NOT NULL AND nullif(btrim(p_password_hash), '') IS NULL THEN
        RAISE EXCEPTION 'Хеш пароля не может быть пустым';
    END IF;
    IF p_roles IS NOT NULL AND (cardinality(p_roles) = 0 OR EXISTS (
        SELECT 1 FROM unnest(p_roles) AS r(role_code)
        WHERE role_code IS NULL OR role_code NOT IN ('CONSTRUCTOR', 'EXECUTOR')
    )) THEN RAISE EXCEPTION 'Укажите хотя бы одну допустимую роль'; END IF;
    UPDATE user_account
    SET login = COALESCE(btrim(p_new_login), login),
        password_hash = COALESCE(p_password_hash, password_hash),
        is_active = COALESCE(p_is_active, is_active),
        session_version = session_version + CASE
            WHEN p_password_hash IS NOT NULL OR p_is_active IS NOT NULL
              OR p_roles IS NOT NULL OR p_new_login IS NOT NULL THEN 1 ELSE 0 END
    WHERE account_id = v_account_id;
    IF p_roles IS NOT NULL THEN
        DELETE FROM user_account_role WHERE account_id = v_account_id;
        INSERT INTO user_account_role(account_id, role_code)
        SELECT v_account_id, r FROM (SELECT DISTINCT unnest(p_roles) AS r) q;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM user_account a
        JOIN user_account_role r ON r.account_id = a.account_id
        JOIN employee e ON e.employee_id = a.employee_id
        JOIN pickup_point p ON p.point_id = e.point_id
        WHERE a.is_active AND e.is_active AND p.is_active
          AND r.role_code = 'CONSTRUCTOR'
    ) THEN RAISE EXCEPTION 'Нельзя оставить приложение без действующего конструктора'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.save_access_group(p_code text, p_name text)
RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
    IF nullif(btrim(p_code), '') IS NULL OR nullif(btrim(p_name), '') IS NULL THEN
        RAISE EXCEPTION 'Код и название группы обязательны';
    END IF;
    INSERT INTO access_group(code, name) VALUES (btrim(p_code), btrim(p_name))
    ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name
    RETURNING group_id INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.set_access_group_active(p_code text, p_active boolean)
RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
    IF p_active IS NULL THEN RAISE EXCEPTION 'Признак активности группы обязателен'; END IF;
    SELECT group_id INTO v_id FROM access_group WHERE code = p_code FOR UPDATE;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Группа % не найдена', p_code; END IF;
    IF NOT p_active AND (
        EXISTS (SELECT 1 FROM employee_group WHERE group_id = v_id)
        OR EXISTS (SELECT 1 FROM state_access WHERE group_id = v_id)
        OR EXISTS (SELECT 1 FROM decision_access WHERE group_id = v_id)
    ) THEN RAISE EXCEPTION 'Группа % используется; сначала снимите назначения и права', p_code; END IF;
    UPDATE access_group SET is_active = p_active WHERE group_id = v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.set_employee_group(
    p_employee_code text, p_group_code text, p_grant boolean
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_employee_id bigint; v_group_id bigint;
BEGIN
    IF p_grant IS NULL THEN RAISE EXCEPTION 'Действие назначения обязательно'; END IF;
    SELECT employee_id INTO v_employee_id FROM employee
    WHERE code = p_employee_code AND (is_active OR NOT p_grant);
    SELECT group_id INTO v_group_id FROM access_group
    WHERE code = p_group_code AND (is_active OR NOT p_grant);
    IF v_employee_id IS NULL OR v_group_id IS NULL THEN
        RAISE EXCEPTION 'Сотрудник или группа не найдены / неактивны';
    END IF;
    IF p_grant THEN
        INSERT INTO employee_group(employee_id, group_id)
        VALUES (v_employee_id, v_group_id) ON CONFLICT DO NOTHING;
    ELSE
        DELETE FROM employee_group WHERE employee_id = v_employee_id AND group_id = v_group_id;
    END IF;
    UPDATE user_account SET session_version = session_version + 1
    WHERE employee_id = v_employee_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.set_state_access(
    p_template_code text, p_state_code text, p_group_code text, p_grant boolean
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_template_id bigint; v_state_id bigint; v_group_id bigint;
BEGIN
    IF p_grant IS NULL THEN RAISE EXCEPTION 'Действие разрешения обязательно'; END IF;
    v_template_id := pvz_lab.require_draft(p_template_code);
    SELECT state_id INTO v_state_id FROM template_state
    WHERE template_id = v_template_id AND code = p_state_code;
    SELECT group_id INTO v_group_id FROM access_group
    WHERE code = p_group_code AND (is_active OR NOT p_grant);
    IF v_state_id IS NULL OR v_group_id IS NULL THEN
        RAISE EXCEPTION 'Состояние или группа не найдены / неактивны';
    END IF;
    IF p_grant THEN
        INSERT INTO state_access(state_id, group_id)
        VALUES (v_state_id, v_group_id) ON CONFLICT DO NOTHING;
    ELSE
        DELETE FROM decision_access WHERE state_id = v_state_id AND group_id = v_group_id;
        DELETE FROM state_access WHERE state_id = v_state_id AND group_id = v_group_id;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.set_decision_access(
    p_template_code text, p_state_code text, p_decision_code text,
    p_group_code text, p_grant boolean
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_template_id bigint; v_state_id bigint; v_decision_id bigint; v_group_id bigint;
BEGIN
    IF p_grant IS NULL THEN RAISE EXCEPTION 'Действие разрешения обязательно'; END IF;
    v_template_id := pvz_lab.require_draft(p_template_code);
    SELECT state_id INTO v_state_id FROM template_state
    WHERE template_id = v_template_id AND code = p_state_code;
    SELECT decision_id INTO v_decision_id FROM decision_type WHERE code = p_decision_code;
    SELECT group_id INTO v_group_id FROM access_group
    WHERE code = p_group_code AND (is_active OR NOT p_grant);
    IF v_state_id IS NULL OR v_decision_id IS NULL OR v_group_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM state_decision WHERE state_id = v_state_id AND decision_id = v_decision_id
    ) THEN RAISE EXCEPTION 'Состояние, решение или группа не найдены / не связаны'; END IF;
    IF p_grant THEN
        IF NOT EXISTS (SELECT 1 FROM state_access
                       WHERE state_id = v_state_id AND group_id = v_group_id) THEN
            RAISE EXCEPTION 'Сначала выдайте группе доступ к состоянию';
        END IF;
        INSERT INTO decision_access(state_id, decision_id, group_id)
        VALUES (v_state_id, v_decision_id, v_group_id) ON CONFLICT DO NOTHING;
    ELSE
        DELETE FROM decision_access WHERE state_id = v_state_id
            AND decision_id = v_decision_id AND group_id = v_group_id;
    END IF;
END;
$$;
COMMIT;
