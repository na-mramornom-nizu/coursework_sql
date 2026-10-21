                                                                                  
                                               
BEGIN;
SET search_path TO pvz_lab, pg_temp;

ALTER TABLE pickup_point
    ADD COLUMN address text,
    ADD COLUMN is_active boolean NOT NULL DEFAULT true;
ALTER TABLE employee
    ADD COLUMN is_active boolean NOT NULL DEFAULT true;
ALTER TABLE access_group
    ADD COLUMN is_active boolean NOT NULL DEFAULT true;

                                                                                   
ALTER TABLE process_template
    ADD COLUMN family_code text,
    ADD COLUMN status text NOT NULL DEFAULT 'DRAFT',
    ADD COLUMN published_at timestamptz,
    ADD COLUMN previous_template_id bigint REFERENCES process_template(template_id);

                                                                          
UPDATE process_template
SET family_code = code,
    status = CASE WHEN is_active THEN 'PUBLISHED' ELSE 'DRAFT' END,
    published_at = CASE WHEN is_active THEN clock_timestamp() ELSE NULL END;

ALTER TABLE process_template
    ALTER COLUMN family_code SET NOT NULL,
    ALTER COLUMN is_active SET DEFAULT false,
    ADD CONSTRAINT template_status_check CHECK (
        (status = 'DRAFT' AND NOT is_active AND published_at IS NULL)
        OR (status = 'PUBLISHED' AND is_active AND published_at IS NOT NULL)
        OR (status = 'ARCHIVED' AND NOT is_active AND published_at IS NOT NULL)
    ),
    ADD CONSTRAINT template_family_nonempty CHECK (btrim(family_code) <> ''),
    ADD CONSTRAINT template_name_nonempty CHECK (btrim(name) <> '');

CREATE UNIQUE INDEX template_family_version_unique
    ON process_template(family_code, version_no);
CREATE UNIQUE INDEX template_one_published_per_family
    ON process_template(family_code) WHERE status = 'PUBLISHED';

CREATE OR REPLACE FUNCTION pvz_lab.template_set_family()
RETURNS trigger LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
BEGIN
    IF NEW.family_code IS NULL THEN
        NEW.family_code := NEW.code;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER template_set_family_before_insert
    BEFORE INSERT ON process_template
    FOR EACH ROW EXECUTE FUNCTION pvz_lab.template_set_family();

CREATE TABLE user_account (
    account_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id bigint NOT NULL UNIQUE REFERENCES employee(employee_id),
    login text NOT NULL,
    password_hash text NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    session_version bigint NOT NULL DEFAULT 1 CHECK (session_version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT account_login_nonempty CHECK (btrim(login) <> ''),
    CONSTRAINT account_hash_nonempty CHECK (btrim(password_hash) <> '')
);
CREATE UNIQUE INDEX user_account_login_ci_unique ON user_account(lower(login));

CREATE TABLE user_account_role (
    account_id bigint NOT NULL REFERENCES user_account(account_id) ON DELETE CASCADE,
    role_code text NOT NULL CHECK (role_code IN ('CONSTRUCTOR', 'EXECUTOR')),
    PRIMARY KEY (account_id, role_code)
);

CREATE INDEX employee_point_idx ON employee(point_id);
CREATE INDEX order_point_idx ON pickup_order(point_id, external_no);
CREATE INDEX template_family_idx ON process_template(family_code, version_no DESC);

COMMENT ON TABLE user_account IS 'Учётная запись приложения, связанная с одним сотрудником';
COMMENT ON TABLE user_account_role IS 'Роли интерфейса; не заменяют предметные access_group';
COMMENT ON COLUMN process_template.status IS 'DRAFT / PUBLISHED / ARCHIVED';
COMMIT;
