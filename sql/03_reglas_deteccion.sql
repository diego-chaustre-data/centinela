-- =====================================================================
--  CENTINELA · 03 · REGLAS DE DETECCIÓN
--
--  Cada regla es una VISTA: una consulta que devuelve los casos sospechosos.
--  Todas devuelven las mismas columnas, así el motor las trata igual:
--     cliente_id, cuenta_id, ventana_inicio, ventana_fin,
--     num_transacciones, monto_involucrado, evidencia, explicacion
--
--  Para agregar una regla nueva basta crear su vista y registrarla en "reglas".
-- =====================================================================

-- ---------- Umbrales configurables -----------------------------------
-- Los de efectivo ($10 M individual, $50 M al mes) son valores de referencia
-- inspirados en los reportes de transacciones en efectivo a la UIAF.
-- Los demás son supuestos de este ejercicio.
INSERT INTO parametros (clave, valor, descripcion) VALUES
    ('efectivo_umbral_individual',    10000000, 'Monto desde el cual una operación en efectivo se reporta por sí sola'),
    ('efectivo_umbral_mensual',       50000000, 'Suma mensual de efectivo de un cliente que obliga a reportar'),
    ('fraccionamiento_min_depositos',        3, 'Mínimo de depósitos para hablar de fraccionamiento'),
    ('puente_monto_minimo',            5000000, 'Dinero recibido en un día para evaluar una cuenta puente'),
    ('puente_min_origenes',                  4, 'Personas distintas que le envían dinero ese día'),
    ('puente_porcentaje_salida',            90, 'Porcentaje de lo recibido que sale el mismo día'),
    ('viaje_velocidad_maxima_kmh',         900, 'Velocidad de un avión comercial: más rápido es imposible'),
    ('perfil_veces_ingreso',                 5, 'Cuántas veces el ingreso declarado puede recibir en un mes'),
    ('perfil_monto_minimo',           15000000, 'Monto mensual mínimo para evaluar el perfil'),
    ('dormida_dias',                       180, 'Días sin movimiento para considerar una cuenta dormida'),
    ('dormida_monto_minimo',           5000000, 'Monto con el que "despierta" la cuenta dormida'),
    ('dispositivo_min_clientes',             3, 'Clientes distintos operados desde un mismo aparato');

-- ---------- Funciones de apoyo ---------------------------------------
CREATE FUNCTION param(p_clave text) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT valor FROM parametros WHERE clave = p_clave
$$;

-- 12345678.90  ->  $12.345.679
CREATE FUNCTION pesos(p_monto numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT '$' || replace(to_char(round(p_monto), 'FM999,999,999,999,990'), ',', '.')
$$;

-- Distancia en kilómetros entre dos puntos del mapa (fórmula de Haversine)
CREATE FUNCTION distancia_km(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT round((2 * 6371 * asin(sqrt(
               power(sin(radians(lat2 - lat1) / 2), 2)
             + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
           )))::numeric, 1)
$$;

-- =====================================================================
--  R1 · EFECTIVO FRACCIONADO ("pitufeo")
--  Varios depósitos en efectivo, cada uno por debajo del umbral individual,
--  que sumados en el mes superan el umbral mensual.
--  Técnica: GROUP BY + HAVING
-- =====================================================================
CREATE VIEW v_r1_efectivo_fraccionado AS
SELECT cu.cliente_id,
       NULL::int                                          AS cuenta_id,
       date_trunc('month', t.fecha)                       AS ventana_inicio,
       date_trunc('month', t.fecha) + interval '1 month'  AS ventana_fin,
       count(*)::int                                      AS num_transacciones,
       sum(t.monto)                                       AS monto_involucrado,
       array_agg(t.id ORDER BY t.fecha)                   AS evidencia,
       format('En %s hizo %s depósitos en efectivo, todos por debajo de %s (el más alto fue de %s). '
              'Sumados dan %s, por encima del tope mensual de %s. '
              'Partir el dinero en montos pequeños es la forma clásica de evitar el reporte.',
              to_char(date_trunc('month', t.fecha), 'MM/YYYY'), count(*),
              pesos(param('efectivo_umbral_individual')), pesos(max(t.monto)),
              pesos(sum(t.monto)), pesos(param('efectivo_umbral_mensual')))  AS explicacion
FROM transacciones t
JOIN cuentas cu ON cu.id = t.cuenta_id
WHERE t.tipo = 'deposito_efectivo'
  AND t.monto < param('efectivo_umbral_individual')
GROUP BY cu.cliente_id, date_trunc('month', t.fecha)
HAVING sum(t.monto) >= param('efectivo_umbral_mensual')
   AND count(*)     >= param('fraccionamiento_min_depositos');

-- =====================================================================
--  R2 · CUENTA PUENTE ("mula")
--  En un mismo día la cuenta recibe dinero de muchas personas distintas
--  y casi todo vuelve a salir. La cuenta solo sirve de paso.
--  Técnica: GROUP BY con agregados filtrados (FILTER) y COUNT(DISTINCT)
-- =====================================================================
CREATE VIEW v_r2_cuenta_puente AS
SELECT cu.cliente_id,
       t.cuenta_id,
       date_trunc('day', t.fecha)                      AS ventana_inicio,
       date_trunc('day', t.fecha) + interval '1 day'   AS ventana_fin,
       count(*)::int                                   AS num_transacciones,
       sum(t.monto) FILTER (WHERE t.tipo = 'transferencia_recibida')  AS monto_involucrado,
       array_agg(t.id ORDER BY t.fecha)                AS evidencia,
       format('El %s recibió %s de %s personas distintas y ese mismo día salió %s (el %s%% de lo recibido). '
              'El dinero no se queda: la cuenta se usa solo para pasarlo a otro lado.',
              to_char(date_trunc('day', t.fecha), 'DD/MM/YYYY'),
              pesos(sum(t.monto) FILTER (WHERE t.tipo = 'transferencia_recibida')),
              count(DISTINCT coalesce(t.contraparte_cuenta_id::text, t.contraparte_externa))
                  FILTER (WHERE t.tipo = 'transferencia_recibida'),
              pesos(sum(t.monto) FILTER (WHERE t.tipo <> 'transferencia_recibida')),
              round(100 * sum(t.monto) FILTER (WHERE t.tipo <> 'transferencia_recibida')
                        / sum(t.monto) FILTER (WHERE t.tipo = 'transferencia_recibida')))  AS explicacion
FROM transacciones t
JOIN cuentas cu ON cu.id = t.cuenta_id
WHERE t.tipo IN ('transferencia_recibida', 'transferencia_enviada', 'retiro_efectivo')
GROUP BY cu.cliente_id, t.cuenta_id, date_trunc('day', t.fecha)
HAVING sum(t.monto) FILTER (WHERE t.tipo = 'transferencia_recibida') >= param('puente_monto_minimo')
   AND count(DISTINCT coalesce(t.contraparte_cuenta_id::text, t.contraparte_externa))
           FILTER (WHERE t.tipo = 'transferencia_recibida') >= param('puente_min_origenes')
   AND coalesce(sum(t.monto) FILTER (WHERE t.tipo <> 'transferencia_recibida'), 0)
           >= sum(t.monto) FILTER (WHERE t.tipo = 'transferencia_recibida') * param('puente_porcentaje_salida') / 100;

-- =====================================================================
--  R3 · VIAJE IMPOSIBLE (tarjeta clonada)
--  Dos operaciones presenciales seguidas de la misma cuenta, en ciudades
--  tan lejanas que ni en avión se alcanza a llegar.
--  Técnica: función de ventana LAG() + distancia de Haversine
-- =====================================================================
CREATE VIEW v_r3_viaje_imposible AS
WITH presenciales AS (
    SELECT t.id, t.cuenta_id, t.fecha, t.monto, t.ciudad_id,
           LAG(t.id)        OVER w AS id_anterior,
           LAG(t.fecha)     OVER w AS fecha_anterior,
           LAG(t.ciudad_id) OVER w AS ciudad_anterior
    FROM transacciones t
    WHERE t.ciudad_id IS NOT NULL
    WINDOW w AS (PARTITION BY t.cuenta_id ORDER BY t.fecha, t.id)
), saltos AS (
    SELECT p.*,
           c1.nombre AS desde, c2.nombre AS hasta,
           distancia_km(c1.latitud, c1.longitud, c2.latitud, c2.longitud) AS km,
           greatest(extract(epoch FROM (p.fecha - p.fecha_anterior)) / 3600.0, 0.01) AS horas
    FROM presenciales p
    JOIN ciudades c1 ON c1.id = p.ciudad_anterior
    JOIN ciudades c2 ON c2.id = p.ciudad_id
    WHERE p.ciudad_id <> p.ciudad_anterior
)
SELECT cu.cliente_id,
       s.cuenta_id,
       s.fecha_anterior              AS ventana_inicio,
       s.fecha                       AS ventana_fin,
       2                             AS num_transacciones,
       s.monto                       AS monto_involucrado,
       ARRAY[s.id_anterior, s.id]    AS evidencia,
       format('La tarjeta se usó en %s y %s minutos después en %s, a %s km. '
              'Para lograrlo habría que viajar a %s km/h. El cliente no pudo estar en los dos sitios: '
              'una de las dos operaciones no la hizo él.',
              s.desde, round(s.horas * 60), s.hasta, round(s.km), round(s.km / s.horas))  AS explicacion
FROM saltos s
JOIN cuentas cu ON cu.id = s.cuenta_id
WHERE s.km / s.horas > param('viaje_velocidad_maxima_kmh');

-- =====================================================================
--  R4 · MOVIMIENTO NO COHERENTE CON EL PERFIL
--  El cliente recibe en un mes muchas veces lo que declaró ganar.
--  (No cuenta el dinero que pasa entre sus propias cuentas.)
--  Técnica: JOIN de 4 tablas + GROUP BY + HAVING
-- =====================================================================
CREATE VIEW v_r4_fuera_de_perfil AS
SELECT cl.id                                              AS cliente_id,
       NULL::int                                          AS cuenta_id,
       date_trunc('month', t.fecha)                       AS ventana_inicio,
       date_trunc('month', t.fecha) + interval '1 month'  AS ventana_fin,
       count(*)::int                                      AS num_transacciones,
       sum(t.monto)                                       AS monto_involucrado,
       array_agg(t.id ORDER BY t.fecha)                   AS evidencia,
       format('Declaró ingresos de %s al mes, pero en %s recibió %s: %s veces más. '
              'El dinero que mueve no corresponde con lo que dijo ganar.',
              pesos(cl.ingresos_mensuales), to_char(date_trunc('month', t.fecha), 'MM/YYYY'),
              pesos(sum(t.monto)), round(sum(t.monto) / cl.ingresos_mensuales, 1))  AS explicacion
FROM transacciones t
JOIN cuentas  cu ON cu.id = t.cuenta_id
JOIN clientes cl ON cl.id = cu.cliente_id
LEFT JOIN cuentas otra ON otra.id = t.contraparte_cuenta_id
WHERE t.tipo IN ('deposito_efectivo', 'transferencia_recibida')
  AND otra.cliente_id IS DISTINCT FROM cl.id
GROUP BY cl.id, cl.ingresos_mensuales, date_trunc('month', t.fecha)
HAVING sum(t.monto) >= cl.ingresos_mensuales * param('perfil_veces_ingreso')
   AND sum(t.monto) >= param('perfil_monto_minimo');

-- =====================================================================
--  R5 · CUENTA DORMIDA QUE DESPIERTA
--  Una cuenta sin movimientos durante meses recibe o mueve de golpe
--  una suma grande.
--  Técnica: función de ventana LAG() para medir el tiempo entre movimientos
-- =====================================================================
CREATE VIEW v_r5_cuenta_dormida AS
WITH movimientos AS (
    SELECT t.id, t.cuenta_id, t.fecha, t.monto,
           LAG(t.id)    OVER w AS id_anterior,
           LAG(t.fecha) OVER w AS fecha_anterior
    FROM transacciones t
    WINDOW w AS (PARTITION BY t.cuenta_id ORDER BY t.fecha, t.id)
)
SELECT cu.cliente_id,
       m.cuenta_id,
       m.fecha_anterior              AS ventana_inicio,
       m.fecha                       AS ventana_fin,
       2                             AS num_transacciones,
       m.monto                       AS monto_involucrado,
       ARRAY[m.id_anterior, m.id]    AS evidencia,
       format('La cuenta llevaba %s días sin ningún movimiento y de repente movió %s. '
              'Las cuentas abandonadas son las preferidas para mover dinero sin que el dueño lo note.',
              extract(day FROM (m.fecha - m.fecha_anterior))::int, pesos(m.monto))  AS explicacion
FROM movimientos m
JOIN cuentas cu ON cu.id = m.cuenta_id
WHERE m.fecha - m.fecha_anterior >= param('dormida_dias') * interval '1 day'
  AND m.monto >= param('dormida_monto_minimo');

-- =====================================================================
--  R6 · UN MISMO DISPOSITIVO, MUCHOS CLIENTES
--  Desde un solo celular o computador se manejan cuentas de varias
--  personas distintas: alguien controla cuentas que no son suyas.
--  Técnica: CTE + COUNT(DISTINCT) + JOIN
-- =====================================================================
CREATE VIEW v_r6_dispositivo_compartido AS
WITH compartidos AS (
    SELECT t.dispositivo, count(DISTINCT cu.cliente_id) AS clientes
    FROM transacciones t
    JOIN cuentas cu ON cu.id = t.cuenta_id
    WHERE t.dispositivo IS NOT NULL
    GROUP BY t.dispositivo
    HAVING count(DISTINCT cu.cliente_id) >= param('dispositivo_min_clientes')
)
SELECT cu.cliente_id,
       t.cuenta_id,
       min(t.fecha)                       AS ventana_inicio,
       max(t.fecha)                       AS ventana_fin,
       count(*)::int                      AS num_transacciones,
       sum(t.monto)                       AS monto_involucrado,
       array_agg(t.id ORDER BY t.fecha)   AS evidencia,
       format('Su cuenta se operó desde el dispositivo %s, el mismo desde el que se manejan cuentas de %s clientes distintos. '
              'Desde ese aparato salieron %s de esta cuenta. Una sola persona está controlando cuentas ajenas.',
              c.dispositivo, c.clientes, pesos(sum(t.monto)))  AS explicacion
FROM transacciones t
JOIN compartidos c ON c.dispositivo = t.dispositivo
JOIN cuentas cu ON cu.id = t.cuenta_id
GROUP BY cu.cliente_id, t.cuenta_id, c.dispositivo, c.clientes;

-- ---------- Catálogo de reglas ---------------------------------------
INSERT INTO reglas (codigo, nombre, que_detecta, vista, severidad, puntos) VALUES
    ('R1', 'Efectivo fraccionado (pitufeo)',
           'Depósitos en efectivo partidos en montos pequeños para no llegar al tope de reporte.',
           'v_r1_efectivo_fraccionado', 'alta', 40),
    ('R2', 'Cuenta puente (mula)',
           'Cuenta que recibe de muchas personas y saca casi todo el mismo día.',
           'v_r2_cuenta_puente', 'critica', 50),
    ('R3', 'Viaje imposible',
           'Dos usos presenciales de la tarjeta en ciudades demasiado lejanas para el tiempo transcurrido.',
           'v_r3_viaje_imposible', 'critica', 45),
    ('R4', 'Fuera de perfil',
           'El cliente recibe en un mes muchas veces el ingreso que declaró.',
           'v_r4_fuera_de_perfil', 'media', 25),
    ('R5', 'Cuenta dormida que despierta',
           'Cuenta sin movimiento durante meses que de golpe mueve una suma grande.',
           'v_r5_cuenta_dormida', 'alta', 35),
    ('R6', 'Dispositivo compartido',
           'Un mismo celular o computador opera cuentas de varios clientes.',
           'v_r6_dispositivo_compartido', 'alta', 40);

-- ---------- El motor --------------------------------------------------
-- Recorre las reglas activas y guarda como alerta cada caso nuevo.
-- Se puede ejecutar todas las noches: ON CONFLICT evita duplicar lo ya detectado.
CREATE FUNCTION detectar_fraude() RETURNS TABLE (regla text, alertas_nuevas int)
LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT codigo, vista FROM reglas WHERE activa ORDER BY codigo LOOP
        EXECUTE format(
            'INSERT INTO alertas (regla_codigo, cliente_id, cuenta_id, ventana_inicio, ventana_fin,
                                  num_transacciones, monto_involucrado, evidencia, explicacion)
             SELECT %L, cliente_id, cuenta_id, ventana_inicio, ventana_fin,
                    num_transacciones, monto_involucrado, evidencia, explicacion
             FROM %I
             ON CONFLICT DO NOTHING', r.codigo, r.vista);
        GET DIAGNOSTICS alertas_nuevas = ROW_COUNT;
        regla := r.codigo;
        RETURN NEXT;
    END LOOP;
END $$;

-- ---------- Puntaje de riesgo por cliente -----------------------------
-- Suma los puntos de cada regla distinta que el cliente disparó (sin contar
-- las alertas descartadas), +10 si es PEP, con tope de 100.
CREATE VIEW v_riesgo_clientes AS
WITH por_regla AS (
    SELECT a.cliente_id, a.regla_codigo, r.puntos,
           count(*)                 AS alertas,
           sum(a.monto_involucrado) AS monto
    FROM alertas a
    JOIN reglas r ON r.codigo = a.regla_codigo
    WHERE a.estado <> 'descartada'
    GROUP BY a.cliente_id, a.regla_codigo, r.puntos
)
SELECT cl.id AS cliente_id, cl.nombre, cl.documento, ci.nombre AS ciudad, cl.ocupacion,
       cl.ingresos_mensuales, cl.es_pep,
       least(100, sum(p.puntos) + CASE WHEN cl.es_pep THEN 10 ELSE 0 END)::int  AS puntaje,
       string_agg(p.regla_codigo, ', ' ORDER BY p.regla_codigo)                 AS reglas,
       sum(p.alertas)::int                                                     AS alertas,
       sum(p.monto)                                                            AS monto_involucrado
FROM por_regla p
JOIN clientes cl ON cl.id = p.cliente_id
JOIN ciudades ci ON ci.id = cl.ciudad_id
GROUP BY cl.id, cl.nombre, cl.documento, ci.nombre, cl.ocupacion, cl.ingresos_mensuales, cl.es_pep;
