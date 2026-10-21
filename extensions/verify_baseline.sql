                                                
                                                                       
SELECT
    (SELECT count(*) FROM information_schema.tables
     WHERE table_schema = 'pvz_lab' AND table_type = 'BASE TABLE') AS tables_created,
    (SELECT count(*) FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pvz_lab') AS functions_created,
    (SELECT count(*) FROM pvz_lab.process_type) AS process_types,
    (SELECT count(*) FROM pvz_lab.process_template) AS templates,
    (SELECT count(*) FROM pvz_lab.template_state) AS states,
    (SELECT count(*) FROM pvz_lab.decision_type) AS decisions,
    (SELECT count(*) FROM pvz_lab.guard_clause) AS transition_rules,
    (SELECT count(*) FROM pvz_lab.access_group) AS access_groups,
    (SELECT count(*) FROM pvz_lab.employee) AS employees,
    (SELECT count(*) FROM pvz_lab.pickup_point) AS pickup_points,
    (SELECT count(*) FROM pvz_lab.user_account) AS user_accounts,
    (SELECT count(*) FROM pvz_lab.pickup_order) AS orders,
    (SELECT count(*) FROM pvz_lab.process_instance) AS process_instances,
    (SELECT count(*) FROM pvz_lab.process_trajectory) AS trajectory_rows;

                                                    
SELECT o.external_no, p.code AS pickup_point_code, o.is_damaged,
       o.expected_at, o.storage_until
FROM pvz_lab.pickup_order o
JOIN pvz_lab.pickup_point p ON p.point_id = o.point_id
ORDER BY o.external_no;
