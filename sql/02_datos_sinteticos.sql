-- =====================================================================
--  CENTINELA · 02 · DATOS SINTÉTICOS
--
--  Genera un año de operación del banco (nov 2025 – oct 2026):
--    · 2.000 clientes y 2.500 cuentas
--    · ~130.000 transacciones de comportamiento normal
--    · fraude escondido a propósito (ver sección B), para poder medir
--      después si las reglas lo encuentran
--
--  Todo es inventado. setseed() hace que salgan siempre los mismos datos.
-- =====================================================================

SELECT setseed(0.42);

-- ---------- Ciudades -------------------------------------------------
INSERT INTO ciudades (id, nombre, departamento, latitud, longitud) VALUES
    (1,  'Bogotá',        'Cundinamarca',       4.71100, -74.07210),
    (2,  'Medellín',      'Antioquia',          6.24420, -75.58120),
    (3,  'Cali',          'Valle del Cauca',    3.45160, -76.53200),
    (4,  'Barranquilla',  'Atlántico',         10.96850, -74.78130),
    (5,  'Cartagena',     'Bolívar',           10.39100, -75.47940),
    (6,  'Cúcuta',        'Norte de Santander', 7.89390, -72.50780),
    (7,  'Bucaramanga',   'Santander',          7.11930, -73.12270),
    (8,  'Pereira',       'Risaralda',          4.81330, -75.69610),
    (9,  'Santa Marta',   'Magdalena',         11.24080, -74.19900),
    (10, 'Ibagué',        'Tolima',             4.43890, -75.23220),
    (11, 'Pasto',         'Nariño',             1.21360, -77.28110),
    (12, 'Villavicencio', 'Meta',               4.14200, -73.62660);

-- ---------- Clientes -------------------------------------------------
INSERT INTO clientes (id, documento, nombre, ciudad_id, ocupacion, ingresos_mensuales, es_pep, fecha_vinculacion)
SELECT g,
       'DOC-' || lpad(g::text, 6, '0'),
       (ARRAY['Andrés','Camila','Juan','Valentina','Carlos','Daniela','Luis','Paola','Jorge','Natalia',
              'Sergio','Laura','Felipe','Mariana','Óscar','Carolina','Miguel','Adriana','David','Sandra',
              'Julián','Diana','Ricardo','Tatiana','Fernando','Liliana','Héctor','Yuliana','Mauricio','Angélica',
              'Cristian','Mónica','Esteban','Lorena','Germán','Viviana','Iván','Claudia','Nicolás','Marcela'])[1 + floor(random()*40)::int]
       || ' ' ||
       (ARRAY['Rodríguez','Gómez','González','Martínez','García','López','Hernández','Sánchez','Ramírez','Pérez',
              'Díaz','Muñoz','Rojas','Moreno','Jiménez','Vargas','Castro','Ortiz','Suárez','Torres',
              'Gutiérrez','Rincón','Mendoza','Cárdenas','Pabón','Contreras','Villamizar','Peñaranda','Quintero','Jaimes'])[1 + floor(random()*30)::int]
       || ' ' ||
       (ARRAY['Rodríguez','Gómez','González','Martínez','García','López','Hernández','Sánchez','Ramírez','Pérez',
              'Díaz','Muñoz','Rojas','Moreno','Jiménez','Vargas','Castro','Ortiz','Suárez','Torres',
              'Gutiérrez','Rincón','Mendoza','Cárdenas','Pabón','Contreras','Villamizar','Peñaranda','Quintero','Jaimes'])[1 + floor(random()*30)::int],
       (ARRAY[1,1,1,1,1,2,2,2,3,3,4,4,5,6,6,7,7,8,9,10,11,12])[1 + floor(random()*22)::int],
       (ARRAY['Empleado','Empleado','Empleado','Empleada doméstica','Docente','Conductor','Independiente',
              'Independiente','Vendedor','Enfermera','Ingeniero','Contador','Pensionado','Estudiante','Auxiliar administrativo'])[1 + floor(random()*15)::int],
       round(1300000 * (1 + 9 * power(random(), 3)) / 50000) * 50000,   -- entre $1,3 M y $13 M, la mayoría bajos
       random() < 0.01,
       date '2015-01-01' + floor(random()*3800)::int
FROM generate_series(1, 2000) AS g;

-- Perfiles fijos para los escenarios de la sección B
UPDATE clientes SET ocupacion = 'Empleado',    ingresos_mensuales = 1500000 + (id % 4) * 150000 WHERE id BETWEEN 22 AND 29;
UPDATE clientes SET ocupacion = 'Comerciante', ingresos_mensuales = 60000000                    WHERE id BETWEEN 53 AND 57;

-- ---------- Cuentas --------------------------------------------------
-- Las cuentas 1..2000 son la cuenta principal del cliente con el mismo id.
-- Las 2001..2500 son segundas cuentas de clientes al azar.
INSERT INTO cuentas (id, numero, cliente_id, tipo, fecha_apertura)
SELECT x.id,
       '4810-' || lpad(x.id::text, 6, '0'),
       x.cliente_id,
       (CASE WHEN x.r < 0.8 THEN 'ahorros' ELSE 'corriente' END)::tipo_cuenta,
       cl.fecha_vinculacion + CASE WHEN x.id <= 2000 THEN 0 ELSE 30 + (x.id % 60) END
FROM (SELECT g AS id,
             CASE WHEN g <= 2000 THEN g ELSE 61 + floor(random()*1940)::int END AS cliente_id,
             random() AS r
      FROM generate_series(1, 2500) AS g) AS x
JOIN clientes cl ON cl.id = x.cliente_id;

-- Todo se arma primero en una tabla temporal y al final se inserta ordenado
-- por fecha, como llegaría a un banco de verdad.
CREATE TEMP TABLE carga (
    cuenta_id int, fecha timestamp, tipo tipo_transaccion, canal canal, monto numeric(14,2),
    ciudad_id smallint, contraparte_cuenta_id int, contraparte_externa text, dispositivo text
);

-- =====================================================================
--  A · COMPORTAMIENTO NORMAL
--  (las cuentas 41..57 están reservadas para la sección B)
-- =====================================================================

-- A1 · Compras, pagos PSE, retiros y depósitos, proporcionales al ingreso del cliente
INSERT INTO carga
WITH base AS MATERIALIZED (
    SELECT 1 + floor(random()*2500)::int AS cuenta_id,
           timestamp '2025-11-01' + floor(random()*365)::int * interval '1 day'
                                  + floor(21600 + random()*61200)::int * interval '1 second' AS fecha,  -- entre 6 a. m. y 11 p. m.
           random() AS r_tipo, random() AS r_canal, random() AS r_monto
    FROM generate_series(1, 80000)
), clasificada AS (
    SELECT b.*, cl.id AS cliente_id, cl.ciudad_id AS ciudad_casa, cl.ingresos_mensuales AS ingreso,
           extract(week FROM b.fecha)::int AS semana,
           (CASE WHEN r_tipo < 0.50 THEN 'compra_tarjeta'
                 WHEN r_tipo < 0.68 THEN 'pago_pse'
                 WHEN r_tipo < 0.89 THEN 'retiro_efectivo'
                 ELSE 'deposito_efectivo' END)::tipo_transaccion AS tipo
    FROM base b
    JOIN cuentas  cu ON cu.id = b.cuenta_id
    JOIN clientes cl ON cl.id = cu.cliente_id
    WHERE b.cuenta_id NOT BETWEEN 41 AND 57
), con_canal AS (
    SELECT c.*,
           (CASE c.tipo
                WHEN 'compra_tarjeta'  THEN CASE WHEN r_canal < 0.80 THEN 'datafono' ELSE 'web' END
                WHEN 'pago_pse'        THEN CASE WHEN r_canal < 0.50 THEN 'web' ELSE 'app' END
                WHEN 'retiro_efectivo' THEN CASE WHEN r_canal < 0.85 THEN 'cajero' WHEN r_canal < 0.95 THEN 'oficina' ELSE 'corresponsal' END
                ELSE                        CASE WHEN r_canal < 0.50 THEN 'oficina' WHEN r_canal < 0.85 THEN 'corresponsal' ELSE 'cajero' END
            END)::canal AS canal
    FROM clasificada c
)
SELECT cuenta_id, fecha, tipo, canal,
       CASE tipo
           WHEN 'compra_tarjeta'  THEN greatest( 5000, round(ingreso * (0.005 + 0.08 * r_monto * r_monto) / 100)   * 100)
           WHEN 'pago_pse'        THEN greatest(20000, round(ingreso * (0.02  + 0.15 * r_monto * r_monto) / 100)   * 100)
           WHEN 'retiro_efectivo' THEN greatest(20000, round(ingreso * (0.02  + 0.20 * r_monto * r_monto) / 10000) * 10000)
           ELSE                        greatest(50000, round(ingreso * (0.05  + 0.50 * r_monto * r_monto) / 1000)  * 1000)
       END,
       -- La gente usa su tarjeta en su ciudad; algunas semanas "viaja" y la usa en otra.
       CASE WHEN canal IN ('app', 'web') THEN NULL
            WHEN (cuenta_id * 7 + semana * 13) % 23 = 0 THEN 1 + (cuenta_id + semana) % 12
            ELSE ciudad_casa END::smallint,
       NULL,
       CASE tipo
           WHEN 'compra_tarjeta' THEN (ARRAY['Supermercado','Restaurante','Estación de servicio','Droguería','Tienda de ropa',
                                             'Ferretería','Panadería','Tienda de tecnología','Cine','Papelería'])[1 + floor(r_canal * 1000)::int % 10]
           WHEN 'pago_pse'       THEN (ARRAY['Energía eléctrica','Acueducto','Gas natural','Internet y TV','Telefonía celular',
                                             'Impuesto predial','Matrícula educativa','Seguro'])[1 + floor(r_canal * 1000)::int % 8]
       END,
       CASE WHEN canal IN ('app', 'web') THEN 'DSP-' || lpad(cliente_id::text, 5, '0') END
FROM con_canal;

-- A2 · Transferencias: 60 % entre cuentas del banco (dos asientos: sale de una, entra a otra),
--      20 % enviadas a otros bancos y 20 % recibidas de otros bancos
CREATE TEMP TABLE transf AS
SELECT 1 + floor(random()*2500)::int AS origen,
       1 + floor(random()*2500)::int AS destino,
       timestamp '2025-11-01' + floor(random()*365)::int * interval '1 day'
                              + floor(21600 + random()*61200)::int * interval '1 second' AS fecha,
       random() AS r_ext, random() AS r_monto,
       (CASE WHEN random() < 0.7 THEN 'app' ELSE 'web' END)::canal AS canal,
       'Otro banco ****' || floor(1000 + random()*9000)::int AS externa
FROM generate_series(1, 15000);

DELETE FROM transf
WHERE origen = destino OR origen BETWEEN 41 AND 57 OR destino BETWEEN 41 AND 57;

-- lado que envía
INSERT INTO carga
SELECT t.origen, t.fecha, 'transferencia_enviada', t.canal,
       greatest(10000, round(cl.ingresos_mensuales * (0.03 + 0.40 * t.r_monto * t.r_monto) / 1000) * 1000),
       NULL,
       CASE WHEN t.r_ext < 0.6 THEN t.destino END,
       CASE WHEN t.r_ext >= 0.6 THEN t.externa END,
       'DSP-' || lpad(cl.id::text, 5, '0')
FROM transf t
JOIN cuentas  cu ON cu.id = t.origen
JOIN clientes cl ON cl.id = cu.cliente_id
WHERE t.r_ext < 0.8;

-- lado que recibe (mismo monto y misma hora que el envío interno)
INSERT INTO carga
SELECT t.destino, t.fecha, 'transferencia_recibida', t.canal,
       greatest(10000, round((CASE WHEN t.r_ext < 0.6 THEN cl_o.ingresos_mensuales ELSE cl_d.ingresos_mensuales END)
                             * (0.03 + 0.40 * t.r_monto * t.r_monto) / 1000) * 1000),
       NULL,
       CASE WHEN t.r_ext < 0.6 THEN t.origen END,
       CASE WHEN t.r_ext >= 0.8 THEN t.externa END,
       NULL
FROM transf t
JOIN cuentas  cu_o ON cu_o.id = t.origen
JOIN clientes cl_o ON cl_o.id = cu_o.cliente_id
JOIN cuentas  cu_d ON cu_d.id = t.destino
JOIN clientes cl_d ON cl_d.id = cu_d.cliente_id
WHERE t.r_ext < 0.6 OR t.r_ext >= 0.8;

-- A3 · Ingreso mensual de cada cliente (nómina o pago habitual), entre el 25 y el 28
INSERT INTO carga
SELECT cl.id,
       timestamp '2025-11-01' + m * interval '1 month' + (24 + cl.id % 4) * interval '1 day'
                              + interval '8 hours' + (cl.id % 600) * interval '1 minute',
       'transferencia_recibida', 'web', cl.ingresos_mensuales, NULL, NULL,
       'Ingreso mensual · pagador ' || lpad((cl.id % 80)::text, 3, '0'), NULL
FROM clientes cl
CROSS JOIN generate_series(0, 11) AS m
WHERE cl.id NOT BETWEEN 41 AND 57;

-- A4 · Cinco comerciantes legítimos (cuentas 53..57): reciben muchos pagos de muchas
--      personas todos los días, pero el dinero SE QUEDA en la cuenta.
--      Sirven para comprobar que la regla de "cuenta puente" no los confunde con mulas.
INSERT INTO carga
SELECT c.id,
       d + interval '8 hours' + floor(random()*36000)::int * interval '1 second',
       'transferencia_recibida', 'app',
       round((400000 + random()*1600000) / 1000) * 1000,
       NULL, NULL, 'Otro banco ****' || floor(1000 + random()*9000)::int, NULL
FROM generate_series(53, 57) AS c(id)
CROSS JOIN generate_series(timestamp '2025-11-01', timestamp '2026-10-31', interval '1 day') AS d
CROSS JOIN generate_series(1, 7) AS k
WHERE k <= 4 + (extract(doy FROM d)::int + c.id) % 4;

-- =====================================================================
--  B · FRAUDE SEMBRADO  (lo que las reglas deben encontrar)
-- =====================================================================

-- B1 · PITUFEO (clientes 1..8): 7 depósitos en efectivo en un mes, cada uno justo por
--      debajo de $10 M para no ser reportado, que juntos pasan de $50 M.
INSERT INTO carga
SELECT c,
       timestamp '2026-04-01' + (c % 6) * interval '1 month'
           + ((ARRAY[1,4,8,11,15,19,23])[k] + floor(random()*3)::int) * interval '1 day'
           + interval '9 hours' + floor(random()*25200)::int * interval '1 second',
       'deposito_efectivo', (CASE WHEN k % 2 = 0 THEN 'oficina' ELSE 'corresponsal' END)::canal,
       round((7500000 + random()*2400000) / 10000) * 10000,
       cl.ciudad_id, NULL, NULL, NULL
FROM generate_series(1, 8) AS c
JOIN clientes cl ON cl.id = c
CROSS JOIN generate_series(1, 7) AS k;

--      Dos clientes HONESTOS (58 y 59) que vendieron un vehículo y consignaron el pago
--      en efectivo por partes. En los datos se ven igual que un pitufeo: son los
--      falsos positivos que un analista humano debe revisar y descartar.
INSERT INTO carga
SELECT c,
       timestamp '2026-07-01' + (c - 58) * interval '1 month'
           + (2 + k * 3) * interval '1 day' + interval '10 hours' + floor(random()*18000)::int * interval '1 second',
       'deposito_efectivo', 'oficina',
       round((8600000 + random()*1000000) / 10000) * 10000,
       cl.ciudad_id, NULL, NULL, NULL
FROM generate_series(58, 59) AS c
JOIN clientes cl ON cl.id = c
CROSS JOIN generate_series(1, 6) AS k;

-- B2 · CUENTAS MULA (cuentas 9..14): en un solo día reciben transferencias de 5 a 7
--      personas distintas (víctimas de estafa) y por la tarde sacan el 96 % a otro banco.
CREATE TEMP TABLE mula AS
SELECT c AS cuenta,
       timestamp '2026-05-05' + (c - 9) * interval '23 days' AS dia,
       100 + c * 37 + k * 211 AS victima,
       round((1200000 + random()*2300000) / 1000) * 1000 AS monto,
       floor(random()*14400)::int AS segundos
FROM generate_series(9, 14) AS c
CROSS JOIN generate_series(1, 7) AS k
WHERE k <= 5 + c % 3;

INSERT INTO carga      -- la víctima envía
SELECT m.victima, m.dia + interval '9 hours' + m.segundos * interval '1 second',
       'transferencia_enviada', 'app', m.monto, NULL, m.cuenta, NULL,
       'DSP-' || lpad(cu.cliente_id::text, 5, '0')
FROM mula m JOIN cuentas cu ON cu.id = m.victima;

INSERT INTO carga      -- la mula recibe
SELECT m.cuenta, m.dia + interval '9 hours' + m.segundos * interval '1 second',
       'transferencia_recibida', 'app', m.monto, NULL, m.victima, NULL, NULL
FROM mula m;

INSERT INTO carga      -- la mula saca casi todo
SELECT m.cuenta, m.dia + interval '15 hours 20 minutes',
       'transferencia_enviada', 'app', round(sum(m.monto) * 0.96 / 1000) * 1000,
       NULL, NULL, 'Otro banco ****9' || lpad(m.cuenta::text, 3, '0'),
       'DSP-' || lpad(m.cuenta::text, 5, '0')
FROM mula m
GROUP BY m.cuenta, m.dia;

-- B3 · TARJETA CLONADA (cuentas 15..21): el cliente compra en su ciudad y, minutos
--      después, "su" tarjeta retira efectivo en un cajero a cientos de kilómetros.
INSERT INTO carga
SELECT c, f.momento + x.minutos * interval '1 minute', x.tipo, x.canal, x.monto,
       (CASE WHEN x.lejos THEN CASE WHEN cl.ciudad_id IN (4, 5, 9) THEN 11 ELSE 4 END
             ELSE cl.ciudad_id END)::smallint,
       NULL, x.comercio, NULL
FROM generate_series(15, 21) AS c
JOIN clientes cl ON cl.id = c
CROSS JOIN LATERAL (SELECT timestamp '2026-06-03 14:10' + (c - 15) * interval '17 days' AS momento) AS f
CROSS JOIN LATERAL (VALUES
    (0,              'compra_tarjeta'::tipo_transaccion,  'datafono'::canal, (64000 + c * 1300)::numeric, false, 'Supermercado'),
    (12 + c % 10,    'retiro_efectivo'::tipo_transaccion, 'cajero'::canal,   2000000::numeric,            true,  NULL),
    (15 + c % 10,    'retiro_efectivo'::tipo_transaccion, 'cajero'::canal,   1800000::numeric,            true,  NULL)
) AS x(minutos, tipo, canal, monto, lejos, comercio);

-- B4 · NO COHERENTE CON EL PERFIL (clientes 22..29): declararon ganar cerca de $1,5 M
--      y en un mes reciben entre $24 M y $70 M desde otros bancos.
INSERT INTO carga
SELECT c,
       timestamp '2026-03-01' + (c % 5) * interval '1 month' + (2 + k * 4) * interval '1 day'
           + interval '10 hours' + floor(random()*21600)::int * interval '1 second',
       'transferencia_recibida', 'web',
       round((6000000 + random()*6000000) / 1000) * 1000,
       NULL, NULL, 'Otro banco ****' || (7000 + c * 10 + k), NULL
FROM generate_series(22, 29) AS c
CROSS JOIN generate_series(1, 6) AS k
WHERE k <= 4 + c % 3;

-- B5 · CUENTAS DORMIDAS (41..52): tuvieron movimiento en nov 2025 y quedaron quietas.
INSERT INTO carga
SELECT c, timestamp '2025-11-05' + k * interval '6 days' + interval '11 hours' + (c * 7) * interval '1 minute',
       'compra_tarjeta', 'datafono', 40000 + c * 1500 + k * 9000, cl.ciudad_id, NULL, 'Supermercado', NULL
FROM generate_series(41, 52) AS c
JOIN clientes cl ON cl.id = c
CROSS JOIN generate_series(1, 3) AS k;

--      41..46 despiertan con fraude: entra una suma grande y al día siguiente sale el 95 %.
CREATE TEMP TABLE despertar AS
SELECT c AS cuenta,
       timestamp '2026-07-10 10:30' + (c - 41) * interval '16 days' AS momento,
       round((12000000 + random()*18000000) / 1000) * 1000 AS monto
FROM generate_series(41, 46) AS c;

INSERT INTO carga
SELECT cuenta, momento, 'transferencia_recibida', 'web', monto, NULL, NULL, 'Otro banco ****3' || cuenta, NULL
FROM despertar;

INSERT INTO carga
SELECT cuenta, momento + interval '22 hours', 'transferencia_enviada', 'app', round(monto * 0.95 / 1000) * 1000,
       NULL, NULL, 'Otro banco ****8' || cuenta, 'DSP-' || lpad(cuenta::text, 5, '0')
FROM despertar;

--      47..52 despiertan de forma inocente (una compra pequeña): NO deben generar alerta.
INSERT INTO carga
SELECT c, timestamp '2026-08-03 16:00' + (c - 47) * interval '9 days',
       'compra_tarjeta', 'datafono', 60000 + c * 2100, cl.ciudad_id, NULL, 'Droguería', NULL
FROM generate_series(47, 52) AS c
JOIN clientes cl ON cl.id = c;

-- B6 · UN SOLO APARATO, MUCHOS CLIENTES (clientes 30..40): dos celulares desde los que
--      se manejan las cuentas de 6 y 5 personas distintas, y todo sale al mismo destino.
INSERT INTO carga
SELECT c,
       (CASE WHEN c <= 35 THEN timestamp '2026-08-12 19:00' ELSE timestamp '2026-09-21 21:30' END)
           + ((c % 6) * 40 + k * 7) * interval '1 minute',
       'transferencia_enviada', 'app',
       round((2000000 + random()*2000000) / 1000) * 1000,
       NULL, NULL,
       CASE WHEN c <= 35 THEN 'Otro banco ****5521' ELSE 'Otro banco ****5847' END,
       CASE WHEN c <= 35 THEN 'DSP-90001' ELSE 'DSP-90002' END
FROM generate_series(30, 40) AS c
CROSS JOIN generate_series(1, 2) AS k;

-- =====================================================================
--  C · CARGA FINAL, ordenada por fecha
-- =====================================================================
INSERT INTO transacciones (cuenta_id, fecha, tipo, canal, monto, ciudad_id,
                           contraparte_cuenta_id, contraparte_externa, dispositivo)
SELECT cuenta_id, fecha, tipo, canal, monto, ciudad_id,
       contraparte_cuenta_id, contraparte_externa, dispositivo
FROM carga
ORDER BY fecha, cuenta_id;

DROP TABLE carga;
DROP TABLE transf;
DROP TABLE mula;
DROP TABLE despertar;

ANALYZE;
