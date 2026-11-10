-- =====================================================================
--  CENTINELA · 04 · EVALUACIÓN DEL MOTOR
--
--  Como el fraude se sembró a propósito (02, sección B), se puede medir:
--    · ¿encontró todo lo que se escondió?
--    · ¿cuántas alertas levantó sobre clientes que no eran fraude?
--
--  OJO: esto prueba que las reglas hacen lo que dicen sobre datos inventados.
--  NO es una medida de cómo se comportarían con el fraude real de un banco.
-- =====================================================================

INSERT INTO fraude_sembrado (regla_codigo, cliente_id, descripcion)
SELECT 'R1', g, 'Pitufeo: 7 depósitos en efectivo bajo el tope en un mes'              FROM generate_series(1, 8)   AS g UNION ALL
SELECT 'R2', g, 'Mula: recibe de varias víctimas y saca el 96 % el mismo día'          FROM generate_series(9, 14)  AS g UNION ALL
SELECT 'R3', g, 'Tarjeta clonada: retiro en otra ciudad minutos después de una compra' FROM generate_series(15, 21) AS g UNION ALL
SELECT 'R4', g, 'Recibe decenas de millones con ingreso declarado de $1,5 M'           FROM generate_series(22, 29) AS g UNION ALL
SELECT 'R6', g, 'Su cuenta se opera desde un celular que controla varias cuentas'      FROM generate_series(30, 40) AS g UNION ALL
SELECT 'R5', g, 'Cuenta dormida que recibe una suma grande y la saca al día siguiente' FROM generate_series(41, 46) AS g;

-- Resultado por regla
CREATE VIEW v_evaluacion_reglas AS
SELECT r.codigo, r.nombre,
       (SELECT count(*) FROM fraude_sembrado f WHERE f.regla_codigo = r.codigo)::int        AS casos_sembrados,
       (SELECT count(*) FROM fraude_sembrado f
         WHERE f.regla_codigo = r.codigo
           AND EXISTS (SELECT 1 FROM alertas a
                       WHERE a.regla_codigo = r.codigo AND a.cliente_id = f.cliente_id))::int AS casos_encontrados,
       (SELECT count(*) FROM alertas a WHERE a.regla_codigo = r.codigo)::int                 AS alertas_generadas,
       -- alertas sobre clientes que no tienen NINGÚN fraude sembrado: candidatas a falso positivo
       (SELECT count(*) FROM alertas a
         WHERE a.regla_codigo = r.codigo
           AND NOT EXISTS (SELECT 1 FROM fraude_sembrado f WHERE f.cliente_id = a.cliente_id))::int AS alertas_sobre_inocentes
FROM reglas r
ORDER BY r.codigo;

-- Resumen general
CREATE VIEW v_evaluacion_general AS
SELECT (SELECT count(*) FROM transacciones)::int                               AS transacciones_analizadas,
       (SELECT count(*) FROM clientes)::int                                    AS clientes,
       (SELECT count(*) FROM alertas)::int                                     AS alertas,
       (SELECT count(DISTINCT cliente_id) FROM alertas)::int                   AS clientes_con_alerta,
       (SELECT count(DISTINCT cliente_id) FROM fraude_sembrado)::int           AS clientes_con_fraude_sembrado,
       (SELECT count(DISTINCT f.cliente_id) FROM fraude_sembrado f
         WHERE EXISTS (SELECT 1 FROM alertas a
                       WHERE a.cliente_id = f.cliente_id AND a.regla_codigo = f.regla_codigo))::int AS fraudes_encontrados,
       (SELECT count(DISTINCT a.cliente_id) FROM alertas a
         WHERE NOT EXISTS (SELECT 1 FROM fraude_sembrado f WHERE f.cliente_id = a.cliente_id))::int AS inocentes_con_alerta;
