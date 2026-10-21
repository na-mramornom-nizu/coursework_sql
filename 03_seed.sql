                                             
                                                                         
SELECT pvz_lab.create_process_type('PVZ_OPERATIONS', 'Операции пункта выдачи');
SELECT pvz_lab.create_process_type('ORDER_HANDLING', 'Обработка заказа в ПВЗ',
                                   'PVZ_OPERATIONS');
SELECT pvz_lab.create_process_template('ORDER_HANDLING', 'PICKUP_ORDER_V1',
                                       'Обработка заказа от приёмки до выдачи или возврата');

SELECT pvz_lab.add_template_state('PICKUP_ORDER_V1', 'WAITING_RECEIPT',
                                  'Ожидает приёмки', true, false);
SELECT pvz_lab.add_template_state('PICKUP_ORDER_V1', 'ACCEPTED',
                                  'Принят в ПВЗ', false, false);
SELECT pvz_lab.add_template_state('PICKUP_ORDER_V1', 'READY',
                                  'Готов к выдаче', false, false);
SELECT pvz_lab.add_template_state('PICKUP_ORDER_V1', 'RETURN_PREP',
                                  'Подготовка возврата', false, false);
SELECT pvz_lab.add_template_state('PICKUP_ORDER_V1', 'ISSUED',
                                  'Выдан покупателю', false, true);
SELECT pvz_lab.add_template_state('PICKUP_ORDER_V1', 'RETURNED',
                                  'Передан на возврат', false, true);

                                                                              
                                                                                
SELECT pvz_lab.add_transition('PICKUP_ORDER_V1', 'WAITING_RECEIPT',
    'ACCEPT', 'Принять заказ', 'ACCEPTED', 'ORDER_DAMAGED', false);
SELECT pvz_lab.add_transition('PICKUP_ORDER_V1', 'WAITING_RECEIPT',
    'DAMAGED', 'Зафиксировать повреждение', 'RETURN_PREP', 'ORDER_DAMAGED', true);
SELECT pvz_lab.add_transition('PICKUP_ORDER_V1', 'ACCEPTED',
    'PLACE', 'Разместить на хранение', 'READY');
SELECT pvz_lab.add_transition('PICKUP_ORDER_V1', 'READY',
    'HAND_OVER', 'Выдать покупателю', 'ISSUED', 'STORAGE_EXPIRED', false);
SELECT pvz_lab.add_transition('PICKUP_ORDER_V1', 'READY',
    'BUYER_REFUSED', 'Оформить отказ покупателя', 'RETURN_PREP');
SELECT pvz_lab.add_transition('PICKUP_ORDER_V1', 'READY',
    'EXPIRED', 'Оформить невостребованный заказ', 'RETURN_PREP',
    'STORAGE_EXPIRED', true);
SELECT pvz_lab.add_transition('PICKUP_ORDER_V1', 'RETURN_PREP',
    'SEND_BACK', 'Передать в обратную логистику', 'RETURNED');

INSERT INTO pvz_lab.access_group(code, name) VALUES
    ('OPERATOR', 'Оператор ПВЗ'),
    ('ADMIN', 'Администратор процесса'),
    ('GUEST', 'Наблюдатель');

INSERT INTO pvz_lab.pickup_point(code, name)
VALUES ('PVZ-01', 'Учебный ПВЗ № 1');

INSERT INTO pvz_lab.employee(code, full_name, point_id)
SELECT x.code, x.full_name, p.point_id
FROM (VALUES
    ('OP_01', 'Оператор ПВЗ 1'),
    ('AD_01', 'Администратор процесса 1'),
    ('GU_01', 'Наблюдатель 1')
) AS x(code, full_name)
JOIN pvz_lab.pickup_point p ON p.code = 'PVZ-01';

INSERT INTO pvz_lab.employee_group(employee_id, group_id)
SELECT e.employee_id, g.group_id
FROM (VALUES ('OP_01', 'OPERATOR'), ('AD_01', 'ADMIN'),
             ('GU_01', 'GUEST')) AS x(employee_code, group_code)
JOIN pvz_lab.employee e ON e.code = x.employee_code
JOIN pvz_lab.access_group g ON g.code = x.group_code;

INSERT INTO pvz_lab.state_access(state_id, group_id)
SELECT s.state_id, g.group_id
FROM pvz_lab.template_state s
JOIN pvz_lab.process_template t ON t.template_id = s.template_id
CROSS JOIN pvz_lab.access_group g
WHERE t.code = 'PICKUP_ORDER_V1' AND NOT s.is_terminal
  AND g.code IN ('OPERATOR', 'ADMIN');

INSERT INTO pvz_lab.decision_access(state_id, decision_id, group_id)
SELECT sd.state_id, sd.decision_id, g.group_id
FROM pvz_lab.state_decision sd
JOIN pvz_lab.template_state s ON s.state_id = sd.state_id
JOIN pvz_lab.process_template t ON t.template_id = s.template_id
CROSS JOIN pvz_lab.access_group g
WHERE t.code = 'PICKUP_ORDER_V1'
  AND g.code IN ('OPERATOR', 'ADMIN');

INSERT INTO pvz_lab.pickup_order(
    external_no, point_id, expected_at, storage_until, is_damaged
)
SELECT x.external_no, p.point_id, x.expected_at, x.storage_until,
       x.is_damaged
FROM (VALUES
    ('PVZ-ORDER-001', now() - interval '1 day',
        now() + interval '5 days', false),
    ('PVZ-ORDER-002', now() - interval '1 day',
        now() + interval '5 days', true),
    ('PVZ-ORDER-003', now() - interval '10 days',
        now() - interval '1 day', false),
    ('PVZ-ORDER-004', now() - interval '1 day',
        now() + interval '5 days', false)
) AS x(external_no, expected_at, storage_until, is_damaged)
CROSS JOIN pvz_lab.pickup_point p WHERE p.code = 'PVZ-01';

INSERT INTO pvz_lab.order_item(order_id, sku, item_name, quantity)
SELECT o.order_id, x.sku, x.item_name, x.quantity
FROM (VALUES
    ('PVZ-ORDER-001', 'SKU-101', 'Книга', 1),
    ('PVZ-ORDER-001', 'SKU-102', 'Чехол', 1),
    ('PVZ-ORDER-002', 'SKU-201', 'Настольная лампа', 1),
    ('PVZ-ORDER-003', 'SKU-301', 'Блокнот', 2),
    ('PVZ-ORDER-004', 'SKU-401', 'Наушники', 1)
) AS x(external_no, sku, item_name, quantity)
JOIN pvz_lab.pickup_order o ON o.external_no = x.external_no;
