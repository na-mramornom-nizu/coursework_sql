                                                                                 
BEGIN;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pvz_lab.pickup_order WHERE external_no = 'PVZ-ORDER-005') THEN
        PERFORM pvz_lab.create_order('PVZ-ORDER-005', 'PVZ-01', 'OP_01',
            now() - interval '2 hours', now() + interval '7 days',
            '[{"sku":"SKU-501","item_name":"Рюкзак","quantity":1},
              {"sku":"SKU-502","item_name":"Бутылка для воды","quantity":2}]'::jsonb);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pvz_lab.pickup_order WHERE external_no = 'PVZ-ORDER-006') THEN
        PERFORM pvz_lab.create_order('PVZ-ORDER-006', 'PVZ-01', 'OP_01',
            now() - interval '1 day', now() + interval '4 days',
            '[{"sku":"SKU-601","item_name":"Настольная игра","quantity":1}]'::jsonb);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pvz_lab.pickup_order WHERE external_no = 'PVZ-ORDER-007') THEN
        PERFORM pvz_lab.create_order('PVZ-ORDER-007', 'PVZ-01', 'OP_01',
            now() - interval '3 days', now() - interval '1 hour',
            '[{"sku":"SKU-701","item_name":"Кабель USB-C","quantity":3},
              {"sku":"SKU-702","item_name":"Сетевое зарядное устройство","quantity":1}]'::jsonb);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pvz_lab.pickup_order WHERE external_no = 'PVZ-ORDER-008') THEN
        PERFORM pvz_lab.create_order('PVZ-ORDER-008', 'PVZ-01', 'OP_01',
            now() + interval '1 day', now() + interval '10 days',
            '[{"sku":"SKU-801","item_name":"Термокружка","quantity":1}]'::jsonb);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pvz_lab.pickup_order WHERE external_no = 'PVZ-ORDER-009') THEN
        PERFORM pvz_lab.create_order('PVZ-ORDER-009', 'PVZ-01', 'OP_01',
            now() - interval '5 hours', now() + interval '3 days',
            '[{"sku":"SKU-901","item_name":"Ежедневник","quantity":2},
              {"sku":"SKU-902","item_name":"Набор ручек","quantity":1}]'::jsonb);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pvz_lab.pickup_order WHERE external_no = 'PVZ-ORDER-010') THEN
        PERFORM pvz_lab.create_order('PVZ-ORDER-010', 'PVZ-01', 'OP_01',
            now() - interval '1 hour', now() + interval '14 days',
            '[{"sku":"SKU-1001","item_name":"Наушники","quantity":1},
              {"sku":"SKU-1002","item_name":"Чехол для наушников","quantity":1},
              {"sku":"SKU-1003","item_name":"Переходник","quantity":1}]'::jsonb);
    END IF;
END;
$$;
COMMIT;
