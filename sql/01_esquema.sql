-- =====================================================================
--  CENTINELA · Detección de fraude y lavado de activos en SQL
--  01 · ESQUEMA  (PostgreSQL 15 o superior)
--
--  Banco ficticio "Banco Pamplonita". Todos los datos son inventados.
-- =====================================================================

-- ---------- Tipos ----------------------------------------------------
CREATE TYPE tipo_cuenta      AS ENUM ('ahorros', 'corriente');
CREATE TYPE estado_cuenta    AS ENUM ('activa', 'bloqueada', 'cerrada');
CREATE TYPE tipo_transaccion AS ENUM ('deposito_efectivo', 'retiro_efectivo',
                                      'transferencia_recibida', 'transferencia_enviada',
                                      'compra_tarjeta', 'pago_pse');
CREATE TYPE canal            AS ENUM ('oficina', 'cajero', 'corresponsal', 'datafono', 'app', 'web');
CREATE TYPE severidad        AS ENUM ('media', 'alta', 'critica');
CREATE TYPE estado_alerta    AS ENUM ('nueva', 'en_revision', 'descartada', 'reportada_ros');

-- ---------- Tablas maestras -----------------------------------------
CREATE TABLE ciudades (
    id           smallint PRIMARY KEY,
    nombre       text NOT NULL UNIQUE,
    departamento text NOT NULL,
    latitud      numeric(8,5) NOT NULL,
    longitud     numeric(8,5) NOT NULL
);

CREATE TABLE clientes (
    id                 int PRIMARY KEY,
    documento          text NOT NULL UNIQUE,          -- ficticio: DOC-000001
    nombre             text NOT NULL,
    ciudad_id          smallint NOT NULL REFERENCES ciudades(id),
    ocupacion          text NOT NULL,
    ingresos_mensuales numeric(14,2) NOT NULL CHECK (ingresos_mensuales > 0),  -- lo que el cliente DECLARÓ ganar
    es_pep             boolean NOT NULL DEFAULT false, -- Persona Expuesta Políticamente
    fecha_vinculacion  date NOT NULL
);

CREATE TABLE cuentas (
    id             int PRIMARY KEY,
    numero         text NOT NULL UNIQUE,
    cliente_id     int NOT NULL REFERENCES clientes(id),
    tipo           tipo_cuenta NOT NULL,
    fecha_apertura date NOT NULL,
    estado         estado_cuenta NOT NULL DEFAULT 'activa'
);
CREATE INDEX idx_cuentas_cliente ON cuentas(cliente_id);

-- ---------- Transacciones (el libro del banco) -----------------------
CREATE TABLE transacciones (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cuenta_id             int NOT NULL REFERENCES cuentas(id),
    fecha                 timestamp NOT NULL,          -- hora de Colombia
    tipo                  tipo_transaccion NOT NULL,
    canal                 canal NOT NULL,
    monto                 numeric(14,2) NOT NULL CHECK (monto > 0),
    ciudad_id             smallint REFERENCES ciudades(id),   -- dónde ocurrió (solo canales físicos)
    contraparte_cuenta_id int REFERENCES cuentas(id),         -- la otra cuenta, si es de este banco
    contraparte_externa   text,                               -- la otra parte, si es de afuera
    dispositivo           text,                               -- celular o computador (solo app y web)

    -- Los canales físicos tienen ciudad; los digitales no.
    CONSTRAINT chk_ciudad_segun_canal
        CHECK ((canal IN ('app', 'web')) = (ciudad_id IS NULL)),
    -- Solo la app y la web registran dispositivo.
    CONSTRAINT chk_dispositivo_solo_digital
        CHECK (dispositivo IS NULL OR canal IN ('app', 'web')),
    -- Una transferencia siempre tiene exactamente una contraparte.
    CONSTRAINT chk_transferencia_con_contraparte
        CHECK (tipo NOT IN ('transferencia_recibida', 'transferencia_enviada')
               OR ((contraparte_cuenta_id IS NOT NULL) <> (contraparte_externa IS NOT NULL))),
    -- Nadie se transfiere a su misma cuenta.
    CONSTRAINT chk_no_autotransferencia
        CHECK (contraparte_cuenta_id IS NULL OR contraparte_cuenta_id <> cuenta_id)
);
CREATE INDEX idx_tx_cuenta_fecha ON transacciones(cuenta_id, fecha);
CREATE INDEX idx_tx_tipo_fecha   ON transacciones(tipo, fecha);
CREATE INDEX idx_tx_dispositivo  ON transacciones(dispositivo) WHERE dispositivo IS NOT NULL;

-- ---------- Motor de detección --------------------------------------
-- Los umbrales viven en una tabla, no dentro del código:
-- cumplimiento puede ajustarlos sin tocar las consultas.
CREATE TABLE parametros (
    clave       text PRIMARY KEY,
    valor       numeric NOT NULL,
    descripcion text NOT NULL
);

CREATE TABLE reglas (
    codigo      text PRIMARY KEY,           -- R1, R2, ...
    nombre      text NOT NULL,
    que_detecta text NOT NULL,
    vista       text NOT NULL UNIQUE,       -- la vista SQL que contiene la regla
    severidad   severidad NOT NULL,
    puntos      int NOT NULL CHECK (puntos BETWEEN 1 AND 100),
    activa      boolean NOT NULL DEFAULT true
);

CREATE TABLE alertas (
    id                int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    regla_codigo      text NOT NULL REFERENCES reglas(codigo),
    cliente_id        int NOT NULL REFERENCES clientes(id),
    cuenta_id         int REFERENCES cuentas(id),     -- NULL si la regla mira al cliente completo
    ventana_inicio    timestamp NOT NULL,
    ventana_fin       timestamp NOT NULL,
    num_transacciones int NOT NULL,
    monto_involucrado numeric(16,2) NOT NULL,
    evidencia         bigint[] NOT NULL,              -- ids de las transacciones que dispararon la alerta
    explicacion       text NOT NULL,                  -- en lenguaje sencillo, para el analista
    estado            estado_alerta NOT NULL DEFAULT 'nueva',
    analista          text,
    nota_analista     text,
    creada_en         timestamp NOT NULL DEFAULT now(),
    -- Correr la detección dos veces no duplica alertas.
    CONSTRAINT uq_alerta UNIQUE NULLS NOT DISTINCT (regla_codigo, cliente_id, cuenta_id, ventana_inicio)
);
CREATE INDEX idx_alertas_cliente ON alertas(cliente_id);
CREATE INDEX idx_alertas_estado  ON alertas(estado);

-- Quién cambió qué alerta, cuándo y por qué.
CREATE TABLE bitacora_alertas (
    id              int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    alerta_id       int NOT NULL REFERENCES alertas(id),
    estado_anterior estado_alerta NOT NULL,
    estado_nuevo    estado_alerta NOT NULL,
    analista        text NOT NULL,
    nota            text,
    fecha           timestamp NOT NULL DEFAULT now()
);

-- Solo para medir el motor: qué fraude se sembró a propósito en los datos.
-- Un banco real NO tiene esta tabla; aquí sirve para comprobar que las reglas funcionan.
CREATE TABLE fraude_sembrado (
    regla_codigo text NOT NULL REFERENCES reglas(codigo),
    cliente_id   int  NOT NULL REFERENCES clientes(id),
    descripcion  text NOT NULL,
    PRIMARY KEY (regla_codigo, cliente_id)
);

-- ---------- Protecciones --------------------------------------------
-- 1) El libro de transacciones y la bitácora son de solo-agregar:
--    nadie puede modificar ni borrar lo que ya pasó.
CREATE FUNCTION bloquear_cambios() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'La tabla "%" es de solo-agregar: no se permite %.', TG_TABLE_NAME, TG_OP;
END $$;

CREATE TRIGGER trg_transacciones_inmutables
    BEFORE UPDATE OR DELETE ON transacciones
    FOR EACH ROW EXECUTE FUNCTION bloquear_cambios();
CREATE TRIGGER trg_transacciones_sin_truncate
    BEFORE TRUNCATE ON transacciones
    FOR EACH STATEMENT EXECUTE FUNCTION bloquear_cambios();

CREATE TRIGGER trg_bitacora_inmutable
    BEFORE UPDATE OR DELETE ON bitacora_alertas
    FOR EACH ROW EXECUTE FUNCTION bloquear_cambios();
CREATE TRIGGER trg_bitacora_sin_truncate
    BEFORE TRUNCATE ON bitacora_alertas
    FOR EACH STATEMENT EXECUTE FUNCTION bloquear_cambios();

-- 2) Cada cambio de estado de una alerta queda registrado, exige responsable,
--    y un reporte ya enviado a la UIAF no se puede deshacer.
CREATE FUNCTION registrar_cambio_alerta() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.estado = OLD.estado THEN
        RETURN NEW;
    END IF;
    IF OLD.estado = 'reportada_ros' THEN
        RAISE EXCEPTION 'La alerta % ya fue reportada (ROS): su estado no se puede cambiar.', OLD.id;
    END IF;
    IF coalesce(trim(NEW.analista), '') = '' THEN
        RAISE EXCEPTION 'Todo cambio de estado debe indicar el analista responsable.';
    END IF;
    IF NEW.estado IN ('descartada', 'reportada_ros') AND coalesce(trim(NEW.nota_analista), '') = '' THEN
        RAISE EXCEPTION 'Para descartar o reportar una alerta hay que escribir la justificación.';
    END IF;
    INSERT INTO bitacora_alertas (alerta_id, estado_anterior, estado_nuevo, analista, nota)
    VALUES (OLD.id, OLD.estado, NEW.estado, NEW.analista, NEW.nota_analista);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_alertas_bitacora
    BEFORE UPDATE ON alertas
    FOR EACH ROW EXECUTE FUNCTION registrar_cambio_alerta();
