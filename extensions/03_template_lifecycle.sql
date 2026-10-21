                                                                           
                                            
BEGIN;
SET search_path TO pvz_lab, pg_temp;

CREATE OR REPLACE FUNCTION pvz_lab.protect_template_child()
RETURNS trigger LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_template_id bigint; v_state_id bigint; v_status text;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        IF TG_TABLE_NAME IN ('template_state', 'guard_predicate', 'guard_clause',
                             'guard_clause_predicate') THEN
            v_template_id := OLD.template_id;
        ELSE
            v_state_id := OLD.state_id;
            SELECT template_id INTO v_template_id FROM template_state WHERE state_id = v_state_id;
        END IF;
        SELECT status INTO v_status FROM process_template WHERE template_id = v_template_id;
        IF v_status IS DISTINCT FROM 'DRAFT' THEN
            RAISE EXCEPTION 'Состав опубликованного шаблона изменять нельзя';
        END IF;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        IF TG_TABLE_NAME IN ('template_state', 'guard_predicate', 'guard_clause',
                             'guard_clause_predicate') THEN
            v_template_id := NEW.template_id;
        ELSE
            v_state_id := NEW.state_id;
            SELECT template_id INTO v_template_id FROM template_state WHERE state_id = v_state_id;
        END IF;
        SELECT status INTO v_status FROM process_template WHERE template_id = v_template_id;
        IF v_status IS DISTINCT FROM 'DRAFT' THEN
            RAISE EXCEPTION 'Состав опубликованного шаблона изменять нельзя';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;



DO $$
DECLARE v_name text;
BEGIN
    FOREACH v_name IN ARRAY ARRAY[
        'template_state', 'state_decision', 'state_access', 'decision_access',
        'guard_predicate', 'guard_clause', 'guard_clause_predicate'
    ] LOOP
        EXECUTE format('CREATE TRIGGER coursework_protect_%I BEFORE INSERT OR UPDATE OR DELETE ON pvz_lab.%I FOR EACH ROW EXECUTE FUNCTION pvz_lab.protect_template_child()',
                       v_name, v_name);
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.protect_decision_type()
RETURNS trigger LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM state_decision sd
        JOIN template_state s ON s.state_id = sd.state_id
        JOIN process_template t ON t.template_id = s.template_id
        WHERE sd.decision_id = OLD.decision_id AND t.status <> 'DRAFT'
    ) OR EXISTS (SELECT 1 FROM process_trajectory WHERE decision_id = OLD.decision_id) THEN
        RAISE EXCEPTION 'Решение используется опубликованным шаблоном или историей';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;
CREATE TRIGGER coursework_protect_decision_type
    BEFORE UPDATE OR DELETE ON decision_type
    FOR EACH ROW EXECUTE FUNCTION pvz_lab.protect_decision_type();

CREATE OR REPLACE VIEW pvz_lab.v_template_transitions AS
SELECT gc.template_id, gc.clause_id,
       src.state_id AS source_state_id, src.code AS source_code,
       d.decision_id, d.code AS decision_code,
       tgt.state_id AS target_state_id, tgt.code AS target_code,
       cond.kind AS condition_kind, cond.expected_bool
FROM guard_clause gc
JOIN template_state tgt ON tgt.state_id = gc.target_state_id
JOIN LATERAL (
    SELECT s.state_id, s.code
    FROM guard_clause_predicate gcp
    JOIN guard_predicate gp ON gp.predicate_id = gcp.predicate_id
    JOIN template_state s ON s.state_id = gp.state_id
    WHERE gcp.clause_id = gc.clause_id AND gp.kind = 'STATE_IS'
    LIMIT 1
) src ON true
JOIN LATERAL (
    SELECT dt.decision_id, dt.code
    FROM guard_clause_predicate gcp
    JOIN guard_predicate gp ON gp.predicate_id = gcp.predicate_id
    JOIN decision_type dt ON dt.decision_id = gp.decision_id
    WHERE gcp.clause_id = gc.clause_id AND gp.kind = 'DECISION_IS'
    LIMIT 1
) d ON true
LEFT JOIN LATERAL (
    SELECT gp.kind, gp.expected_bool
    FROM guard_clause_predicate gcp
    JOIN guard_predicate gp ON gp.predicate_id = gcp.predicate_id
    WHERE gcp.clause_id = gc.clause_id
      AND gp.kind IN ('ORDER_DAMAGED', 'STORAGE_EXPIRED')
    LIMIT 1
) cond ON true;

CREATE OR REPLACE FUNCTION pvz_lab.create_draft_template(
    p_type_code text, p_code text, p_name text
) RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_type_id bigint; v_id bigint;
BEGIN
    IF nullif(btrim(p_code), '') IS NULL OR nullif(btrim(p_name), '') IS NULL THEN
        RAISE EXCEPTION 'Код и название шаблона обязательны';
    END IF;
    SELECT type_id INTO v_type_id FROM process_type WHERE code = p_type_code;
    IF v_type_id IS NULL THEN RAISE EXCEPTION 'Тип процесса % не найден', p_type_code; END IF;
    INSERT INTO process_template(type_id, code, name, family_code, status, is_active)
    VALUES (v_type_id, btrim(p_code), btrim(p_name), btrim(p_code), 'DRAFT', false)
    RETURNING template_id INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.update_draft_template(
    p_template_code text, p_name text
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
    IF nullif(btrim(p_name), '') IS NULL THEN RAISE EXCEPTION 'Название шаблона обязательно'; END IF;
    v_id := pvz_lab.require_draft(p_template_code);
    UPDATE process_template SET name = btrim(p_name) WHERE template_id = v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.update_draft_state(
    p_template_code text, p_state_code text, p_new_code text, p_name text,
    p_is_initial boolean, p_is_terminal boolean
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_template_id bigint; v_state_id bigint;
BEGIN
    v_template_id := pvz_lab.require_draft(p_template_code);
    SELECT state_id INTO v_state_id FROM template_state
    WHERE template_id = v_template_id AND code = p_state_code FOR UPDATE;
    IF v_state_id IS NULL THEN RAISE EXCEPTION 'Состояние % не найдено', p_state_code; END IF;
    IF nullif(btrim(p_new_code), '') IS NULL OR nullif(btrim(p_name), '') IS NULL
       OR p_is_initial IS NULL OR p_is_terminal IS NULL THEN
        RAISE EXCEPTION 'Заполните код, название и признаки состояния';
    END IF;
    IF p_is_terminal AND EXISTS (
        SELECT 1 FROM state_decision WHERE state_id = v_state_id
    ) THEN RAISE EXCEPTION 'Состояние с исходящим переходом не может быть конечным'; END IF;
    IF p_is_initial AND EXISTS (
        SELECT 1 FROM guard_clause WHERE target_state_id = v_state_id
    ) THEN RAISE EXCEPTION 'Состояние с входящим переходом не может быть начальным'; END IF;
    UPDATE template_state SET code = btrim(p_new_code), name = btrim(p_name),
        is_initial = p_is_initial, is_terminal = p_is_terminal
    WHERE state_id = v_state_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.delete_draft_state(
    p_template_code text, p_state_code text
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_template_id bigint; v_state_id bigint;
BEGIN
    v_template_id := pvz_lab.require_draft(p_template_code);
    SELECT state_id INTO v_state_id FROM template_state
    WHERE template_id = v_template_id AND code = p_state_code FOR UPDATE;
    IF v_state_id IS NULL THEN RAISE EXCEPTION 'Состояние % не найдено', p_state_code; END IF;
    IF EXISTS (SELECT 1 FROM state_decision WHERE state_id = v_state_id)
       OR EXISTS (SELECT 1 FROM guard_clause WHERE target_state_id = v_state_id)
       OR EXISTS (SELECT 1 FROM guard_predicate WHERE state_id = v_state_id)
       OR EXISTS (SELECT 1 FROM state_access WHERE state_id = v_state_id)
       OR EXISTS (SELECT 1 FROM decision_access WHERE state_id = v_state_id) THEN
        RAISE EXCEPTION 'Состояние % используется; сначала удалите переходы и права', p_state_code;
    END IF;
    DELETE FROM template_state WHERE state_id = v_state_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.delete_draft_transition(
    p_template_code text, p_from_code text, p_decision_code text
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_template_id bigint; v_state_id bigint; v_decision_id bigint;
        v_clause_ids bigint[]; v_predicate_ids bigint[];
BEGIN
    v_template_id := pvz_lab.require_draft(p_template_code);
    SELECT state_id INTO v_state_id FROM template_state
    WHERE template_id = v_template_id AND code = p_from_code;
    SELECT decision_id INTO v_decision_id FROM decision_type WHERE code = p_decision_code;
    IF v_state_id IS NULL OR v_decision_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM state_decision
        WHERE state_id = v_state_id AND decision_id = v_decision_id
    ) THEN RAISE EXCEPTION 'Переход % / % не найден', p_from_code, p_decision_code; END IF;
    SELECT array_agg(clause_id) INTO v_clause_ids FROM v_template_transitions
    WHERE template_id = v_template_id AND source_state_id = v_state_id
      AND decision_id = v_decision_id;
    IF v_clause_ids IS NULL THEN
        RAISE EXCEPTION 'Для решения % не найдено правило перехода', p_decision_code;
    END IF;
    SELECT array_agg(DISTINCT predicate_id) INTO v_predicate_ids
    FROM guard_clause_predicate WHERE clause_id = ANY(v_clause_ids);
    DELETE FROM decision_access
    WHERE state_id = v_state_id AND decision_id = v_decision_id;
    DELETE FROM guard_clause_predicate WHERE clause_id = ANY(v_clause_ids);
    DELETE FROM guard_clause WHERE clause_id = ANY(v_clause_ids);
    DELETE FROM guard_predicate gp WHERE gp.predicate_id = ANY(v_predicate_ids)
      AND NOT EXISTS (SELECT 1 FROM guard_clause_predicate gcp
                      WHERE gcp.predicate_id = gp.predicate_id);
    DELETE FROM state_decision WHERE state_id = v_state_id AND decision_id = v_decision_id;
    DELETE FROM decision_type d WHERE d.decision_id = v_decision_id
      AND NOT EXISTS (SELECT 1 FROM state_decision sd WHERE sd.decision_id = d.decision_id)
      AND NOT EXISTS (SELECT 1 FROM guard_predicate gp WHERE gp.decision_id = d.decision_id)
      AND NOT EXISTS (SELECT 1 FROM process_trajectory tr WHERE tr.decision_id = d.decision_id);
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.save_draft_transition(
    p_template_code text, p_from_code text, p_decision_code text,
    p_decision_name text, p_to_code text,
    p_condition_kind text DEFAULT NULL, p_expected_bool boolean DEFAULT NULL,
    p_replace_decision_code text DEFAULT NULL
) RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_id bigint; v_existing_name text; v_group_ids bigint[];
        v_state_id bigint; v_decision_id bigint;
BEGIN
    PERFORM pvz_lab.require_draft(p_template_code);
    IF nullif(btrim(p_decision_code), '') IS NULL
       OR nullif(btrim(p_decision_name), '') IS NULL THEN
        RAISE EXCEPTION 'Код и название решения обязательны';
    END IF;
    IF p_replace_decision_code IS NOT NULL THEN
        IF p_replace_decision_code = p_decision_code THEN
            SELECT s.state_id, d.decision_id INTO v_state_id, v_decision_id
            FROM template_state s JOIN process_template t ON t.template_id = s.template_id
            CROSS JOIN decision_type d
            WHERE t.code = p_template_code AND s.code = p_from_code
              AND d.code = p_replace_decision_code;
            SELECT array_agg(group_id) INTO v_group_ids FROM decision_access
            WHERE state_id = v_state_id AND decision_id = v_decision_id;
        END IF;
        PERFORM pvz_lab.delete_draft_transition(
            p_template_code, p_from_code, p_replace_decision_code);
    END IF;
    SELECT name INTO v_existing_name FROM decision_type WHERE code = p_decision_code;
    IF v_existing_name IS NOT NULL AND v_existing_name <> p_decision_name THEN
        RAISE EXCEPTION 'Код решения % уже имеет название %; выберите новый код',
            p_decision_code, v_existing_name;
    END IF;
    v_id := pvz_lab.add_transition(p_template_code, p_from_code,
        p_decision_code, p_decision_name, p_to_code,
        p_condition_kind, p_expected_bool);
    IF v_group_ids IS NOT NULL THEN
        SELECT s.state_id, d.decision_id INTO v_state_id, v_decision_id
        FROM template_state s JOIN process_template t ON t.template_id = s.template_id
        CROSS JOIN decision_type d
        WHERE t.code = p_template_code AND s.code = p_from_code
          AND d.code = p_decision_code;
        INSERT INTO decision_access(state_id, decision_id, group_id)
        SELECT v_state_id, v_decision_id, unnest(v_group_ids);
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.validate_template(p_template_code text)
RETURNS TABLE(issue_code text, issue_text text)
LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_id bigint; v_initial bigint;
BEGIN
    SELECT template_id INTO v_id FROM process_template WHERE code = p_template_code;
    IF v_id IS NULL THEN
        RETURN QUERY SELECT 'NOT_FOUND'::text, 'Шаблон не найден'::text;
        RETURN;
    END IF;
    SELECT state_id INTO v_initial FROM template_state
    WHERE template_id = v_id AND is_initial;
    IF v_initial IS NULL THEN
        RETURN QUERY SELECT 'NO_INITIAL'::text, 'Нет начального состояния'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM template_state WHERE template_id = v_id AND is_terminal) THEN
        RETURN QUERY SELECT 'NO_TERMINAL'::text, 'Нет конечного состояния'::text;
    END IF;
    RETURN QUERY
    SELECT 'NO_OUTGOING'::text, 'У неконечного состояния ' || s.code || ' нет перехода'
    FROM template_state s WHERE s.template_id = v_id AND NOT s.is_terminal
      AND NOT EXISTS (SELECT 1 FROM v_template_transitions t
                      WHERE t.source_state_id = s.state_id);
    RETURN QUERY
    SELECT 'TERMINAL_OUTGOING'::text,
           'Из конечного состояния ' || s.code || ' задан переход'
    FROM template_state s WHERE s.template_id = v_id AND s.is_terminal
      AND EXISTS (SELECT 1 FROM v_template_transitions t
                  WHERE t.source_state_id = s.state_id);
    RETURN QUERY
    SELECT 'NO_RULE'::text,
           'Для состояния ' || s.code || ' и решения ' || d.code || ' нет правила'
    FROM state_decision sd
    JOIN template_state s ON s.state_id = sd.state_id
    JOIN decision_type d ON d.decision_id = sd.decision_id
    WHERE s.template_id = v_id AND NOT EXISTS (
        SELECT 1 FROM v_template_transitions t
        WHERE t.source_state_id = s.state_id AND t.decision_id = d.decision_id);
    RETURN QUERY
    SELECT 'NO_ACCESS'::text,
           'Нет общей группы доступа к состоянию ' || s.code ||
           ' и решению ' || d.code
    FROM state_decision sd
    JOIN template_state s ON s.state_id = sd.state_id
    JOIN decision_type d ON d.decision_id = sd.decision_id
    WHERE s.template_id = v_id AND NOT EXISTS (
        SELECT 1 FROM decision_access da
        JOIN state_access sa ON sa.state_id = da.state_id
                            AND sa.group_id = da.group_id
        JOIN access_group ag ON ag.group_id = da.group_id
        WHERE da.state_id = s.state_id AND da.decision_id = d.decision_id
          AND ag.is_active);
    IF v_initial IS NOT NULL THEN
        RETURN QUERY
        WITH RECURSIVE reached(state_id) AS (
            SELECT v_initial
            UNION
            SELECT t.target_state_id FROM reached r
            JOIN v_template_transitions t ON t.source_state_id = r.state_id
        )
        SELECT 'UNREACHABLE'::text,
               'Состояние ' || s.code || ' недостижимо из начального'
        FROM template_state s WHERE s.template_id = v_id
          AND NOT EXISTS (SELECT 1 FROM reached r WHERE r.state_id = s.state_id);
        RETURN QUERY
        WITH RECURSIVE can_finish(state_id) AS (
            SELECT state_id FROM template_state WHERE template_id = v_id AND is_terminal
            UNION
            SELECT t.source_state_id FROM can_finish c
            JOIN v_template_transitions t ON t.target_state_id = c.state_id
        )
        SELECT 'DEAD_END'::text,
               'Из состояния ' || s.code || ' нельзя достичь конечного'
        FROM template_state s WHERE s.template_id = v_id
          AND NOT EXISTS (SELECT 1 FROM can_finish c WHERE c.state_id = s.state_id);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.protect_template_header()
RETURNS trigger LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'Новый шаблон создаётся только как черновик';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' THEN
        IF OLD.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'Опубликованный шаблон удалить нельзя';
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.status <> 'DRAFT' THEN
        IF OLD.status <> 'PUBLISHED' OR NEW.status <> 'ARCHIVED'
           OR NEW.is_active OR NEW.code IS DISTINCT FROM OLD.code
           OR NEW.name IS DISTINCT FROM OLD.name
           OR NEW.type_id IS DISTINCT FROM OLD.type_id
           OR NEW.version_no IS DISTINCT FROM OLD.version_no
           OR NEW.family_code IS DISTINCT FROM OLD.family_code
           OR NEW.previous_template_id IS DISTINCT FROM OLD.previous_template_id
           OR NEW.published_at IS DISTINCT FROM OLD.published_at THEN
            RAISE EXCEPTION 'Опубликованный шаблон изменять нельзя';
        END IF;
    ELSIF NEW.status = 'PUBLISHED' THEN
        IF EXISTS (SELECT 1 FROM pvz_lab.validate_template(OLD.code)) THEN
            RAISE EXCEPTION 'Шаблон % не прошёл проверку перед публикацией', OLD.code;
        END IF;
    ELSIF NEW.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Черновик можно только опубликовать';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER coursework_protect_template_header
    BEFORE INSERT OR UPDATE OR DELETE ON process_template
    FOR EACH ROW EXECUTE FUNCTION pvz_lab.protect_template_header();

CREATE OR REPLACE FUNCTION pvz_lab.publish_template(p_template_code text)
RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_id bigint; v_family text; v_issues text;
BEGIN
    v_id := pvz_lab.require_draft(p_template_code);
    SELECT family_code INTO v_family FROM process_template WHERE template_id = v_id;
                                                                            
    PERFORM pg_advisory_xact_lock(hashtextextended(v_family, 91231));
    SELECT string_agg(issue_code || ': ' || issue_text, '; ')
    INTO v_issues FROM pvz_lab.validate_template(p_template_code);
    IF v_issues IS NOT NULL THEN RAISE EXCEPTION 'Публикация невозможна: %', v_issues; END IF;
    UPDATE process_template SET status = 'ARCHIVED', is_active = false
    WHERE family_code = v_family AND status = 'PUBLISHED';
    UPDATE process_template
    SET status = 'PUBLISHED', is_active = true, published_at = clock_timestamp()
    WHERE template_id = v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION pvz_lab.clone_template(
    p_source_code text, p_new_code text, p_new_name text
) RETURNS bigint LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
DECLARE v_source process_template%ROWTYPE; v_new_id bigint;
        v_state_map jsonb := '{}'::jsonb; v_pred_map jsonb := '{}'::jsonb;
        v_clause_map jsonb := '{}'::jsonb;
        v_old record; v_new_child bigint;
BEGIN
    IF nullif(btrim(p_new_code), '') IS NULL OR nullif(btrim(p_new_name), '') IS NULL THEN
        RAISE EXCEPTION 'Код и название новой версии обязательны';
    END IF;
    SELECT * INTO v_source FROM process_template WHERE code = p_source_code;
    IF NOT FOUND OR v_source.status <> 'PUBLISHED' THEN
        RAISE EXCEPTION 'Для копирования нужен опубликованный шаблон';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(v_source.family_code, 91231));
    INSERT INTO process_template(type_id, code, name, version_no,
                                 family_code, previous_template_id)
    SELECT v_source.type_id, btrim(p_new_code), btrim(p_new_name),
           max(version_no) + 1, v_source.family_code, v_source.template_id
    FROM process_template WHERE family_code = v_source.family_code
    GROUP BY v_source.type_id, v_source.family_code, v_source.template_id
    RETURNING template_id INTO v_new_id;
    FOR v_old IN SELECT * FROM template_state WHERE template_id = v_source.template_id LOOP
        INSERT INTO template_state(template_id, code, name, is_initial, is_terminal)
        VALUES (v_new_id, v_old.code, v_old.name,
                v_old.is_initial, v_old.is_terminal)
        RETURNING state_id INTO v_new_child;
        v_state_map := v_state_map || jsonb_build_object(v_old.state_id::text, v_new_child);
    END LOOP;
    INSERT INTO state_decision(state_id, decision_id)
    SELECT (v_state_map ->> sd.state_id::text)::bigint, sd.decision_id
    FROM state_decision sd JOIN template_state s ON s.state_id = sd.state_id
    WHERE s.template_id = v_source.template_id;
    INSERT INTO state_access(state_id, group_id)
    SELECT (v_state_map ->> sa.state_id::text)::bigint, sa.group_id
    FROM state_access sa JOIN template_state s ON s.state_id = sa.state_id
    WHERE s.template_id = v_source.template_id;
    INSERT INTO decision_access(state_id, decision_id, group_id)
    SELECT (v_state_map ->> da.state_id::text)::bigint, da.decision_id, da.group_id
    FROM decision_access da JOIN template_state s ON s.state_id = da.state_id
    WHERE s.template_id = v_source.template_id;
    FOR v_old IN SELECT * FROM guard_predicate WHERE template_id = v_source.template_id LOOP
        INSERT INTO guard_predicate(template_id, kind, state_id, decision_id, expected_bool)
        VALUES (v_new_id, v_old.kind,
                CASE WHEN v_old.state_id IS NULL THEN NULL
                     ELSE (v_state_map ->> v_old.state_id::text)::bigint END,
                v_old.decision_id, v_old.expected_bool)
        RETURNING predicate_id INTO v_new_child;
        v_pred_map := v_pred_map || jsonb_build_object(v_old.predicate_id::text, v_new_child);
    END LOOP;
    FOR v_old IN SELECT * FROM guard_clause WHERE template_id = v_source.template_id LOOP
        INSERT INTO guard_clause(template_id, target_state_id, clause_no)
        VALUES (v_new_id, (v_state_map ->> v_old.target_state_id::text)::bigint,
                v_old.clause_no)
        RETURNING clause_id INTO v_new_child;
        v_clause_map := v_clause_map || jsonb_build_object(v_old.clause_id::text, v_new_child);
    END LOOP;
    INSERT INTO guard_clause_predicate(template_id, clause_id, predicate_id, position_no)
    SELECT v_new_id, (v_clause_map ->> gcp.clause_id::text)::bigint,
           (v_pred_map ->> gcp.predicate_id::text)::bigint, gcp.position_no
    FROM guard_clause_predicate gcp JOIN guard_clause gc ON gc.clause_id = gcp.clause_id
    WHERE gc.template_id = v_source.template_id;
    RETURN v_new_id;
END;
$$;

COMMIT;
