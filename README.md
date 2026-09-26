# Frijolero

Frijolero es una app web para la contabilidad personal. Convierte los estados
de cuenta en PDF de bancos, tarjetas y casas de bolsa en archivos de Beancount.

Así funciona:

1. Subes un PDF.
2. La app identifica la cuenta y el periodo, y tú los confirmas.
3. Una corrida en segundo plano extrae las transacciones con un modelo de
   OpenAI o de Anthropic.
4. La corrida aplica las reglas de la cuenta y escribe un archivo `.beancount`.
5. La corrida incluye el archivo en el ledger y hace commit y push.

El ledger es un repo de git con un layout fijo. `bin/new-ledger` crea uno
vacío. Los PDF viven en un bucket compatible con S3, o en disco si no
configuras uno.

## Las secciones de la app

**Estados de cuenta** tiene tres páginas y el botón "Subir estado de cuenta":

- Recientes: el estado de los dos últimos periodos de cada cuenta (recibido,
  pendiente, falta o falló). "falta" lleva a la página de subir y "falló"
  lleva a la corrida que falló.
- Cuentas: las cuentas, los PDF de cada una y los periodos que faltan. Aquí
  das de alta una cuenta y editas su configuración y sus reglas.
- Bitácora: las corridas, con su estado, su hora y su salida. Una corrida
  fallida puede tener el botón "Reintentar".

Al subir un PDF, confirmas la cuenta y el periodo. Si ese estado de cuenta ya
existe, la página lo dice y ofrece "Sobrescribir". "Solo guardar PDF" guarda
el archivo y no extrae nada.

Cada estado de cuenta tiene su página, con dos vistas: Movimientos y
Beancount. En Movimientos, la fecha de un movimiento abre un editor de esa
transacción. "▲ N sin clasificar" lleva a los movimientos sin clasificar y
los resalta. "Hacer regla" crea una regla desde un movimiento.

**Reportes** tiene tres páginas: Estado de resultados, Balance general y
Diario. Los dos reportes van por año, trimestre o mes, en MXN o por moneda.
Cada cifra lleva al Diario, que lista los movimientos detrás de ella.

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
