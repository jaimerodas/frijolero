# Frijolero

Frijolero es una app web para la contabilidad personal. Convierte los estados
de cuenta en PDF de bancos, tarjetas y casas de bolsa en archivos de Beancount.

Así funciona:

1. Subes uno o más PDF, desde la página o desde un atajo de iOS.
2. La app identifica la cuenta y el periodo, y tú los confirmas en la Bandeja.
   El último estado de cuenta de una cuenta no necesita tu confirmación.
3. Una corrida en segundo plano extrae las transacciones con un modelo de
   OpenAI o de Anthropic.
4. La corrida aplica las reglas de la cuenta y escribe un archivo `.beancount`.
5. La corrida incluye el archivo en el ledger y hace commit y push.

El ledger es un repo de git con un layout fijo. `bin/new-ledger` crea uno
vacío. Los PDF viven en un bucket compatible con S3, o en disco si no
configuras uno.

## Las secciones de la app

**Estados de cuenta** tiene tres páginas y el botón "Subir estado de cuenta":

- Recientes: el estado de los dos últimos periodos de cada cuenta: listo,
  "N por revisar", "saldo no cuadra", falta, falló, o el día en que cierra.
  "por revisar" lleva a Revisar, "falta" lleva a la página de subir y "falló"
  lleva a la corrida que falló. "saldo no cuadra" da la diferencia contra el
  saldo del PDF (ver [Los saldos](docs/ledger.md#los-saldos)).
- Cuentas: la configuración y las reglas de cada cuenta, y los archivos del
  ledger que editas aquí. El nombre de una cuenta lleva a sus PDF y a los
  periodos que faltan. Aquí das de alta una cuenta.
- Bitácora: las corridas, con su estado, su hora y su salida. Una corrida
  fallida puede tener el botón "Reintentar".

Los PDF que subes esperan en la Bandeja. Ahí confirmas la cuenta y el periodo
de cada uno, o los cambias. Si ese estado de cuenta ya existe, la Bandeja lo
dice y ofrece "Sobrescribir". "Solo guardar PDF" guarda el archivo y no
extrae nada. Recientes dice cuántos hay por confirmar. Si el PDF es el estado
de cuenta que Recientes espera, la app lo procesa sola (ver
[setup.md](docs/setup.md#sin-confirmar)). Un PDF que se procesa se queda en la
Bandeja con el enlace a su corrida. Después pasa a "Procesados hoy", que dice
qué sigue: por ejemplo, cuántos movimientos hay por revisar.

Desde el iPhone, un atajo de iOS manda los PDF a la Bandeja desde la hoja de
compartir (ver [setup.md](docs/setup.md#subir-desde-el-iphone)).

Cada estado de cuenta tiene su página, con tres vistas: Ver, Editar y el PDF.
En Ver y en el Diario, la fecha de un movimiento abre esa transacción: su
payee, su narración y sus cuentas, con la lista de los payees del ledger y la
de las cuentas abiertas. Si cambias la narración, la original queda en
`source_desc`. Editar abre el texto Beancount en el editor, para la fecha, los
montos o una división.
"Hacer regla" crea una regla desde un movimiento. Mientras queda algo sin
clasificar, el botón amarillo "Revisar" dice cuántos movimientos faltan y abre
Revisar: los movimientos sin clasificar en un solo formulario, con su cuenta,
su payee y su narración. El modelo sugiere tres
cuentas para cada uno, a partir de los movimientos que ya clasificaste, y la
primera ya está en el campo. "Guardar" los guarda todos en un solo commit.

**Reportes** tiene tres páginas: Estado de resultados, Balance general y
Diario. Los dos reportes van por año, trimestre o mes, en MXN o por moneda.
Cada cifra lleva al Diario, que lista los movimientos detrás de ella. En una
cuenta de activo, pasivo o capital, el Diario también da el saldo después de
cada movimiento.

Si el ledger tiene errores, un disco rojo con el número aparece en la barra
de arriba. El disco lleva a la página de errores.

## Documentación

- [Instalar, correr y desplegar](docs/setup.md)
- [El ledger: el repo, las cuentas y los prompts](docs/ledger.md)
- [Las reglas: cómo clasificar las transacciones](docs/rules.md)

## Desarrollo

```bash
bin/test        # rake test y rubocop
```

La versión 2.0.0 reemplazó la herramienta de línea de comandos con esta app.

## Licencia

MIT
