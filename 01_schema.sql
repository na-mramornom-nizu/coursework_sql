                                                                        
                                                                       
CREATE SCHEMA IF NOT EXISTS pvz_lab;
SET search_path TO pvz_lab, public;

CREATE TABLE process_type (
    type_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    parent_type_id bigint REFERENCES process_type(type_id),
    CONSTRAINT process_type_code_nonempty CHECK (btrim(code) <> ''),
    CONSTRAINT process_type_name_nonempty CHECK (btrim(name) <> '')
);

CREATE TABLE process_template (
    template_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    type_id bigint NOT NULL REFERENCES process_type(type_id),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    version_no integer NOT NULL DEFAULT 1 CHECK (version_no > 0),
    is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE template_state (
    state_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    template_id bigint NOT NULL REFERENCES process_template(template_id),
    code text NOT NULL,
    name text NOT NULL,
    is_initial boolean NOT NULL DEFAULT false,
    is_terminal boolean NOT NULL DEFAULT false,
    CONSTRAINT template_state_code_unique UNIQUE (template_id, code),
    CONSTRAINT template_state_id_template_unique UNIQUE (template_id, state_id),
    CONSTRAINT terminal_not_initial CHECK (NOT (is_initial AND is_terminal))
);

CREATE UNIQUE INDEX template_one_initial_state
    ON template_state(template_id) WHERE is_initial;

CREATE TABLE decision_type (
    decision_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL
);

CREATE TABLE pickup_point (
    point_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL
);

CREATE TABLE state_decision (
    state_id bigint NOT NULL REFERENCES template_state(state_id),
    decision_id bigint NOT NULL REFERENCES decision_type(decision_id),
    PRIMARY KEY (state_id, decision_id)
);

CREATE TABLE access_group (
    group_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code text NOT NULL UNIQUE,
    name text NOT NULL
);

CREATE TABLE employee (
    employee_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    point_id bigint NOT NULL REFERENCES pickup_point(point_id),
    code text NOT NULL UNIQUE,
    full_name text NOT NULL
);

CREATE TABLE employee_group (
    employee_id bigint NOT NULL REFERENCES employee(employee_id),
    group_id bigint NOT NULL REFERENCES access_group(group_id),
    PRIMARY KEY (employee_id, group_id)
);

CREATE TABLE state_access (
    state_id bigint NOT NULL REFERENCES template_state(state_id),
    group_id bigint NOT NULL REFERENCES access_group(group_id),
    PRIMARY KEY (state_id, group_id)
);

CREATE TABLE decision_access (
    state_id bigint NOT NULL,
    decision_id bigint NOT NULL,
    group_id bigint NOT NULL REFERENCES access_group(group_id),
    PRIMARY KEY (state_id, decision_id, group_id),
    CONSTRAINT decision_access_state_decision_fk FOREIGN KEY (state_id, decision_id)
        REFERENCES state_decision(state_id, decision_id)
);

                                                      
                                                            
CREATE TABLE guard_predicate (
    predicate_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    template_id bigint NOT NULL REFERENCES process_template(template_id),
    kind text NOT NULL,
    state_id bigint,
    decision_id bigint REFERENCES decision_type(decision_id),
    expected_bool boolean,
    CONSTRAINT guard_predicate_template_unique UNIQUE (template_id, predicate_id),
    CONSTRAINT guard_predicate_state_fk FOREIGN KEY (template_id, state_id)
        REFERENCES template_state(template_id, state_id),
    CONSTRAINT guard_predicate_shape CHECK (
        (kind = 'STATE_IS' AND state_id IS NOT NULL
            AND decision_id IS NULL AND expected_bool IS NULL)
        OR (kind = 'DECISION_IS' AND state_id IS NULL
            AND decision_id IS NOT NULL AND expected_bool IS NULL)
        OR (kind IN ('ORDER_DAMAGED', 'STORAGE_EXPIRED')
            AND state_id IS NULL AND decision_id IS NULL
            AND expected_bool IS NOT NULL)
    )
);

CREATE TABLE guard_clause (
    clause_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    template_id bigint NOT NULL REFERENCES process_template(template_id),
    target_state_id bigint NOT NULL,
    clause_no integer NOT NULL CHECK (clause_no > 0),
    CONSTRAINT guard_clause_template_unique UNIQUE (template_id, clause_id),
    CONSTRAINT guard_clause_target_unique UNIQUE (target_state_id, clause_no),
    CONSTRAINT guard_clause_state_fk FOREIGN KEY (template_id, target_state_id)
        REFERENCES template_state(template_id, state_id)
);

CREATE TABLE guard_clause_predicate (
    template_id bigint NOT NULL,
    clause_id bigint NOT NULL,
    predicate_id bigint NOT NULL,
    position_no integer NOT NULL CHECK (position_no > 0),
    PRIMARY KEY (clause_id, predicate_id),
    CONSTRAINT guard_clause_predicate_position_unique UNIQUE (clause_id, position_no),
    CONSTRAINT guard_clause_predicate_clause_fk FOREIGN KEY (template_id, clause_id)
        REFERENCES guard_clause(template_id, clause_id),
    CONSTRAINT guard_clause_predicate_predicate_fk FOREIGN KEY (template_id, predicate_id)
        REFERENCES guard_predicate(template_id, predicate_id)
);

CREATE TABLE pickup_order (
    order_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    external_no text NOT NULL UNIQUE,
    point_id bigint NOT NULL REFERENCES pickup_point(point_id),
    expected_at timestamptz NOT NULL,
    storage_until timestamptz NOT NULL,
    is_damaged boolean,
    CONSTRAINT storage_after_expected CHECK (storage_until > expected_at)
);

CREATE TABLE order_item (
    item_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id bigint NOT NULL REFERENCES pickup_order(order_id),
    sku text NOT NULL,
    item_name text NOT NULL,
    quantity integer NOT NULL CHECK (quantity > 0),
    CONSTRAINT order_item_sku_unique UNIQUE (order_id, sku)
);

CREATE TABLE process_instance (
    instance_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    template_id bigint NOT NULL REFERENCES process_template(template_id),
    order_id bigint NOT NULL REFERENCES pickup_order(order_id),
    started_by bigint NOT NULL REFERENCES employee(employee_id),
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamptz,
    CONSTRAINT process_instance_per_order_unique UNIQUE (template_id, order_id),
    CONSTRAINT process_instance_template_unique UNIQUE (template_id, instance_id)
);

CREATE TABLE process_trajectory (
    instance_id bigint NOT NULL,
    template_id bigint NOT NULL,
    position_no integer NOT NULL CHECK (position_no > 0),
    state_id bigint NOT NULL,
    decision_id bigint REFERENCES decision_type(decision_id),
    entered_by bigint NOT NULL REFERENCES employee(employee_id),
    entered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    note text,
    PRIMARY KEY (instance_id, position_no),
    CONSTRAINT process_trajectory_instance_fk FOREIGN KEY (template_id, instance_id)
        REFERENCES process_instance(template_id, instance_id),
    CONSTRAINT process_trajectory_state_fk FOREIGN KEY (template_id, state_id)
        REFERENCES template_state(template_id, state_id),
    CONSTRAINT process_trajectory_initial_decision CHECK (
        (position_no = 1 AND decision_id IS NULL)
        OR (position_no > 1 AND decision_id IS NOT NULL)
    )
);

CREATE INDEX process_trajectory_latest
    ON process_trajectory(instance_id, position_no DESC);

COMMENT ON SCHEMA pvz_lab IS 'Учебный каркас описания и исполнения процессов ПВЗ';
COMMENT ON TABLE process_template IS 'Разделяемый шаблон процесса (паттерн Приспособленец)';
COMMENT ON TABLE process_instance IS 'Экземпляр процесса для конкретного заказа';
COMMENT ON TABLE process_trajectory IS 'Упорядоченная история состояний экземпляра процесса';
COMMENT ON TABLE guard_clause IS 'Одна конъюнкция в ДНФ условия запуска состояния';
COMMENT ON TABLE guard_clause_predicate IS 'Предикаты конъюнкции, соединенные логическим И';
