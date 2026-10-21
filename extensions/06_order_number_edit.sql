                                                                              
                                                                           
BEGIN;
CREATE OR REPLACE FUNCTION pvz_lab.update_order_details(
    p_old_external_no text, p_new_external_no text, p_employee_code text,
    p_expected_at timestamptz, p_storage_until timestamptz, p_items jsonb
) RETURNS void LANGUAGE plpgsql SET search_path = pvz_lab, pg_temp AS $$
BEGIN
    IF nullif(btrim(p_new_external_no), '') IS NULL THEN
        RAISE EXCEPTION 'Номер заказа обязателен';
    END IF;
    PERFORM pvz_lab.update_order(p_old_external_no, p_employee_code,
                                  p_expected_at, p_storage_until, p_items);
    UPDATE pickup_order SET external_no = btrim(p_new_external_no)
    WHERE external_no = p_old_external_no;
END;
$$;
COMMIT;
