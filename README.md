# Centinela · Detección de fraude y lavado de activos en SQL

Motor de detección escrito en SQL (PostgreSQL) sobre un banco ficticio con 137.225 transacciones.
Señala seis patrones de fraude y lavado de activos, explica cada alerta en lenguaje sencillo y deja
auditoría de lo que el analista decide.

**Demo en vivo: https://diego-chaustre-data.github.io/centinela/**

La demo corre un **PostgreSQL real dentro del navegador** (PGlite): no necesita servidor ni instalar nada.

> Proyecto de aprendizaje de Diego Chaustre, estudiante SENA de Implementación y Gestión de Bases de Datos,
> construido con asistencia de IA. Todos los datos son inventados. No reemplaza un sistema de monitoreo real.

## El problema

En Colombia las entidades financieras deben vigilar las transacciones de sus clientes y reportar las
operaciones sospechosas a la UIAF (sistema SARLAFT). Con cientos de miles de movimientos al día nadie puede
revisarlos a mano: hace falta que la base de datos señale dónde mirar.

## Las seis reglas

| Regla | Qué detecta | Técnica SQL |
|---|---|---|
| R1 · Efectivo fraccionado (pitufeo) | Depósitos en efectivo partidos para no llegar al tope de reporte | `GROUP BY` + `HAVING` |
| R2 · Cuenta puente (mula) | Recibe de muchas personas y saca casi todo el mismo día | Agregados con `FILTER`, `COUNT(DISTINCT)` |
| R3 · Viaje imposible | La tarjeta aparece en dos ciudades demasiado lejanas en pocos minutos | `LAG()` + distancia de Haversine |
| R4 · Fuera de perfil | Recibe en un mes muchas veces el ingreso que declaró | `JOIN` de 4 tablas + `HAVING` |
| R5 · Cuenta dormida que despierta | Meses sin movimiento y de golpe una suma grande | `LAG()` sobre fechas |
| R6 · Dispositivo compartido | Un mismo celular opera cuentas de varios clientes | CTE + `COUNT(DISTINCT)` |

Cada regla es una **vista**. El motor (`detectar_fraude()`) recorre las reglas activas y guarda los casos nuevos
como alertas. Agregar una regla es crear una vista y registrarla en la tabla `reglas`.

## Lo que cuida la base de datos

- **Libro de solo-agregar**: un disparador impide modificar, borrar o vaciar `transacciones`.
- **Restricciones `CHECK`**: montos positivos, transferencias siempre con una contraparte, ciudad solo en canales físicos.
- **Umbrales en una tabla** (`parametros`), no dentro del código.
- **Bitácora de auditoría**: cada cambio de estado de una alerta queda registrado con analista y justificación.
- **Un reporte enviado no se deshace**: la base rechaza cambiar una alerta ya reportada.
- **Detección repetible**: ejecutarla dos veces no duplica alertas.

## Resultado medido

Los datos se generan con fraude escondido a propósito, así que se puede comprobar si las reglas lo encuentran:

| Regla | Casos sembrados | Encontrados | Alertas | Sobre clientes sin fraude |
|---|---:|---:|---:|---:|
| R1 | 8 | 8 | 10 | 2 |
| R2 | 6 | 6 | 6 | 0 |
| R3 | 7 | 7 | 7 | 0 |
| R4 | 8 | 8 | 22 | 2 |
| R5 | 6 | 6 | 6 | 0 |
| R6 | 11 | 11 | 11 | 0 |

Los 2 clientes sin fraude que aparecen son personas que vendieron un vehículo y consignaron el pago en efectivo
por partes: en los datos se ven igual que un pitufeo, y por eso la decisión final es de un analista.

**Lo que esto prueba y lo que no.** Prueba que cada regla hace lo que dice sobre datos que yo mismo generé.
No dice cómo se comportaría con el fraude real de un banco, que es más variado y más difícil de separar del
comportamiento normal.

## Archivos

| Archivo | Contenido |
|---|---|
| `sql/01_esquema.sql` | Tipos, 9 tablas, índices, disparadores |
| `sql/02_datos_sinteticos.sql` | Generador de clientes, cuentas y transacciones (determinista con `setseed`) |
| `sql/03_reglas_deteccion.sql` | Parámetros, las 6 vistas, el motor y el puntaje de riesgo |
| `sql/04_evaluacion.sql` | Fraude sembrado y vistas de evaluación |
| `index.html` | Panel web: alertas, evidencia, bitácora, calibración y consola SQL |
| `pruebas/probar.mjs` | 20 pruebas automáticas |

## Cómo ejecutarlo

Panel web (necesita un servidor local porque el navegador no carga módulos desde `file://`):

```bash
python -m http.server 8796
```

y abrir `http://localhost:8796`.

Pruebas:

```bash
node pruebas/probar.mjs
```

En un PostgreSQL 15 o superior, ejecutar los cuatro archivos de `sql/` en orden y luego:

```sql
SELECT * FROM detectar_fraude();
SELECT * FROM v_evaluacion_reglas;
```

## Límites conocidos

- Los umbrales de efectivo ($10 M por operación, $50 M al mes) siguen los del reporte de transacciones en efectivo a la UIAF para entidades vigiladas por la Superfinanciera; los demás son supuestos del ejercicio.
- R1, R2 y R4 usan ventanas fijas (mes o día calendario): un patrón que cruza el cambio de mes o la medianoche puede escaparse.
- No se modelan saldos ni listas restrictivas.
- La explicación de cada alerta es una plantilla que arma la base de datos, no un modelo de IA.
- Probado en PGlite 0.5.16 (PostgreSQL compilado a WebAssembly), no en un servidor PostgreSQL instalado.
