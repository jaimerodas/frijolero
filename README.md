# Frijolero

Frijolero es una app web para la contabilidad personal. Convierte los estados
de cuenta en PDF de bancos, tarjetas y casas de bolsa en archivos de Beancount.

Así funciona. Subes un PDF. La app identifica la cuenta y el periodo, y tú
confirmas. Un job en segundo plano extrae las transacciones con OpenAI, aplica
las reglas de la cuenta y escribe un archivo `.beancount`. Después incluye el
archivo en el ledger y hace commit y push. El ledger es un repo de git. Los PDF
viven en Backblaze B2.

Necesitas un ledger: un repo de git con un layout fijo. `bin/new-ledger` crea
uno vacío.

## Las secciones de la app

- **Inicio.** El dashboard muestra, por cuenta, si los últimos dos periodos
  están recibidos, pendientes, faltantes o fallidos.
- **Subir.** Subes un PDF y confirmas la cuenta y el periodo. El botón
  "Solo guardar PDF" guarda el archivo en B2 y no extrae nada.
- **Jobs.** La lista de jobs y la salida de cada uno. Un job que falla muestra
  el error y deja el PDF en el servidor.
- **Cuentas.** Las cuentas del ledger, los PDF de cada una y los periodos que
  faltan. Desde aquí editas la configuración de una cuenta o das de alta una
  cuenta nueva.
- **Reportes.** El estado de resultados y el balance general, por año,
  trimestre o mes, en MXN o por moneda.
- **Estado de cuenta.** Cada estado de cuenta tiene su página. Muestra la lista de
  transacciones, el texto Beancount y el botón "Hacer regla" para las
  transacciones sin clasificar.

## Documentación

- [Instalar, correr y desplegar](docs/setup.md)
- [El ledger: el repo, las cuentas y los prompts](docs/ledger.md)
- [Las reglas: cómo clasificar las transacciones](docs/rules.md)
- [El plan y las decisiones de diseño](docs/webapp-plan.md), en inglés

## Desarrollo

```bash
bin/test        # rake test y rubocop
```

Ruby 4.0.6, de `.ruby-version`. La versión 2.0.0 reemplazó la herramienta de
línea de comandos con esta app.

## Licencia

MIT
