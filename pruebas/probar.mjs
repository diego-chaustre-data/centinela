// Prueba completa de Centinela sobre PostgreSQL (PGlite = PostgreSQL compilado a WebAssembly).
// Uso:  node pruebas/probar.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { PGlite } from '../vendor/pglite/index.js';

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..');
const db = new PGlite();
let fallos = 0;

const ok = (cond, texto) => {
  console.log(`${cond ? '  OK   ' : '  FALLA'}  ${texto}`);
  if (!cond) fallos++;
};
const debeFallar = async (sql, texto) => {
  try { await db.exec(sql); ok(false, texto + ' (no fue rechazado)'); }
  catch { ok(true, texto); }
};

for (const archivo of ['01_esquema.sql', '02_datos_sinteticos.sql', '03_reglas_deteccion.sql', '04_evaluacion.sql']) {
  const t0 = performance.now();
  await db.exec(readFileSync(join(raiz, 'sql', archivo), 'utf8'));
  console.log(`${archivo.padEnd(28)} ${(performance.now() - t0).toFixed(0)} ms`);
}

let t0 = performance.now();
const deteccion = await db.query('SELECT * FROM detectar_fraude()');
console.log(`\ndetectar_fraude()             ${(performance.now() - t0).toFixed(0)} ms`);
console.table(deteccion.rows);

const general = (await db.query('SELECT * FROM v_evaluacion_general')).rows[0];
console.table([general]);
const reglas = (await db.query('SELECT * FROM v_evaluacion_reglas')).rows;
console.table(reglas);

console.log('\nPRUEBAS');
ok(general.transacciones_analizadas > 100000, `más de 100.000 transacciones (${general.transacciones_analizadas})`);
for (const r of reglas) {
  ok(r.casos_encontrados === r.casos_sembrados, `${r.codigo} encontró ${r.casos_encontrados} de ${r.casos_sembrados} casos sembrados`);
}

// Los casos que NO deben generar alerta
const comerciantes = (await db.query(`SELECT count(*)::int n FROM alertas WHERE cliente_id BETWEEN 53 AND 57`)).rows[0].n;
ok(comerciantes === 0, 'los 5 comerciantes legítimos no generan alertas');
const dormidasInocentes = (await db.query(`SELECT count(*)::int n FROM alertas WHERE cliente_id BETWEEN 47 AND 52`)).rows[0].n;
ok(dormidasInocentes === 0, 'las cuentas dormidas que despiertan con una compra pequeña no generan alertas');

// Idempotencia
const segunda = (await db.query('SELECT coalesce(sum(alertas_nuevas),0)::int n FROM detectar_fraude()')).rows[0].n;
ok(segunda === 0, 'ejecutar la detección por segunda vez no duplica alertas');

// Protecciones
await debeFallar(`UPDATE transacciones SET monto = 1 WHERE id = 1`, 'no se puede modificar una transacción');
await debeFallar(`DELETE FROM transacciones WHERE id = 1`, 'no se puede borrar una transacción');
await debeFallar(`TRUNCATE transacciones`, 'no se puede vaciar la tabla de transacciones');
await debeFallar(`INSERT INTO transacciones (cuenta_id, fecha, tipo, canal, monto, ciudad_id) VALUES (1, now(), 'retiro_efectivo', 'cajero', -5, 1)`, 'no se aceptan montos negativos');
await debeFallar(`INSERT INTO transacciones (cuenta_id, fecha, tipo, canal, monto) VALUES (1, now(), 'transferencia_enviada', 'app', 1000)`, 'una transferencia sin contraparte es rechazada');
await debeFallar(`UPDATE alertas SET estado = 'descartada', analista = 'ana' WHERE id = 1`, 'no se puede descartar una alerta sin justificación');
await debeFallar(`UPDATE alertas SET estado = 'en_revision' WHERE id = 1`, 'no se puede cambiar el estado sin indicar el analista');
await db.exec(`UPDATE alertas SET estado = 'reportada_ros', analista = 'ana', nota_analista = 'Prueba' WHERE id = 1`);
const bit = (await db.query(`SELECT count(*)::int n FROM bitacora_alertas WHERE alerta_id = 1`)).rows[0].n;
ok(bit === 1, 'el cambio de estado queda en la bitácora');
await debeFallar(`UPDATE alertas SET estado = 'descartada', analista = 'ana', nota_analista = 'x' WHERE id = 1`, 'una alerta ya reportada no se puede cambiar');
await debeFallar(`DELETE FROM bitacora_alertas`, 'la bitácora no se puede borrar');

console.log(fallos === 0 ? '\nTODO CORRECTO' : `\n${fallos} PRUEBA(S) FALLARON`);
await db.close();
process.exitCode = fallos === 0 ? 0 : 1;
