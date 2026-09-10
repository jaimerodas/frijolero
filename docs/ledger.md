# El ledger

El ledger es tu repo de git, privado. Guarda las transacciones, la configuración de las cuentas, las reglas y los prompts. La
app lee la configuración en cada request y en cada job. Un cambio en el ledger
no necesita un deploy.

## Las tres copias

| Copia | Dónde | Quién escribe |
|---|---|---|
| Laptop | Tu clon en la laptop | Tú, con ediciones a mano en fava. La función de fish `moneys` hace pull, corre fava, y hace commit y push al salir con Ctrl-C. |
| Servidor | `/data/ledger` en el contenedor | La app. Cada job hace pull con rebase al empezar, y commit y push al terminar. Los editores y el diálogo de editar del Diario hacen commit al guardar. |
| GitHub | origin | Nadie de forma directa. |

Antes de cada push, la app hace pull con rebase otra vez. Así integra un push
de la laptop que llegó mientras el job corría. Si el rebase encuentra un
conflicto, la app lo aborta y el job falla. El commit se queda en el servidor.

La función `moneys` está en `contrib/` de este repo. `moneys.fish` va en
`~/.config/fish/functions/` y `moneys.conf.fish` en `~/.config/fish/conf.d/`.
Pon `MONEYS_REPO` y `MONEYS_FAVA_DIR` en tu `config.fish`. Las pruebas de la
función están en [el plan](webapp-plan.md#the-laptop-side-the-moneys-function).

## Crear un ledger

1. Corre `bin/new-ledger <directorio>`. El script crea los archivos iniciales,
   copia los prompts y hace el primer commit.
2. Crea un repo privado en GitHub.
3. Agrega el remoto y haz push:

   ```bash
   git -C <directorio> remote add origin git@github.com:<usuario>/<repo>.git
   git -C <directorio> push -u origin main
   ```

4. En la laptop, pon la ruta en `LEDGER_REPO` de `.env`. En el servidor, clona
   el repo en `/data/ledger`.
5. Abre `/accounts/new` y da de alta la primera cuenta.

Cada job hace `git pull --rebase` al empezar. Sin un remoto, el job falla.

## El layout del repo

```
transactions.beancount        # el archivo principal: transacciones sueltas e includes
moneys.beancount              # lo que abre fava: incluye transactions, account_opens, balances y precios
account_opens.beancount       # un `open` por cada cuenta que no es un commodity
config/accounts.yaml          # las cuentas
config/rules/<Key>.yaml       # las reglas, un archivo por cuenta
config/prompts/<tipo>/        # spec.json, instructions.txt y schema.json
accounts/<Key>/<Key> YYMM.beancount   # un estado de cuenta, con su .json al lado
```

El nombre de un estado de cuenta es la clave de la cuenta, un espacio y el
periodo como `YYMM`. El periodo es el mes que contiene la mayoría de los días
del estado de cuenta. Un estado de AMEX del 4 de agosto al 3 de septiembre es
`2608`.

Los reportes leen `moneys.beancount` con rustledger, así que las opciones,
los opens, los balances y los precios entran en el cálculo.

En B2, los PDF viven en `frijolero/accounts/<Key>/<Key> YYMM.pdf`. El bucket
puede ser compartido con otras apps, porque todo va bajo el prefijo
`frijolero/`.

## config/accounts.yaml

Cada bloque es una cuenta. La clave es el nombre del directorio en
`accounts/` y el prefijo de cada archivo de esa cuenta.

```yaml
AMEX:
  beancount_account: "Liabilities:AMEX"
  openai_prompt_type: default
  description: "Amex credit card (tarjeta de crédito), MXN"
  cutoff_day: 3

Plata:
  beancount_account: "Assets:Investments:Plata"
  openai_prompt_type: plata
  converter_type: plata
  dividend_account: "Income:Dividends:Plata"

Old Card:
  beancount_account: "Liabilities:OldCard"
  openai_prompt_type: default
  closed: true
```

| Llave | Uso |
|---|---|
| `beancount_account` | La cuenta de Beancount donde se registran las transacciones. |
| `openai_prompt_type` | El directorio de `config/prompts/` que extrae este tipo de estado de cuenta. |
| `converter_type` | El pipeline: `cetes_directo`, `fintual` o `plata`. Sin esta llave, el pipeline es Default. Solo Default usa reglas. |
| `description` | La pista que recibe el clasificador. Si falta, usa la clave. |
| `cutoff_day` | El día del mes en que cierra el estado de cuenta. Sin esta llave, el último día del mes. El job lo llena la primera vez que ve un periodo impreso, y nunca lo sobreescribe. |
| `closed` | Con `true`, la cuenta sale del dashboard y del clasificador. Su historial sigue en Cuentas. |

Los pipelines CetesDirecto, Fintual y Plata registran intereses, impuestos y
ganancias en otras cuentas. Estas llaves las nombran. Cada una es opcional.
Sin ella, la transacción va a `Income:FIXME` o `Expenses:FIXME`.

| Llave | Pipelines | Uso |
|---|---|---|
| `counterpart_account` | CetesDirecto, Fintual | La cuenta de donde sale el efectivo y a donde vuelve. Por ejemplo, tu cuenta de banco. |
| `interest_account` | Los tres | Intereses. |
| `tax_account` | CetesDirecto, Fintual | El ISR retenido. |
| `gains_account` | Los tres | Ganancias y pérdidas de capital. |
| `dividend_account` | Fintual, Plata | Dividendos. |
| `fees_account` | Plata | Comisiones. |
| `withholding_account` | Plata | El impuesto retenido en el extranjero. |
| `opening_account` | Plata | La contraparte de una posición transferida desde otro broker. |

Un estado de cuenta que cierra en `cutoff_day` pertenece al mes de 15 días
antes del cierre. El dashboard y el clasificador usan la misma regla.

Edita el bloque de una cuenta en `/accounts/<Key>/config`. Ese editor guarda
solo ese bloque, así los comentarios del resto del archivo sobreviven. Edita
todo el archivo en `/accounts/yaml`. Da de alta una cuenta del pipeline
Default en `/accounts/new`. Las cuentas de los otros pipelines necesitan más
cuentas de Beancount, así que se dan de alta en `/accounts/yaml`.

## config/prompts/\<tipo\>/

Cada `openai_prompt_type` apunta a un directorio con tres archivos:

- `spec.json` fija el modelo y el formato de salida.
- `instructions.txt` es el prompt del sistema.
- `schema.json` es el esquema JSON estricto de la respuesta.

El directorio `classify` es el prompt que lee la cuenta y el periodo de un PDF
subido. La app llena su lista de cuentas desde `accounts.yaml` en cada
llamada.

`templates/prompts/` de este repo tiene los seis: `classify`, `default`,
`bbva`, `cetes`, `fintual` y `plata`. `bin/new-ledger` los copia. El ledger
tiene la copia viva. Un cambio en un prompt es un commit en el ledger.

## Las cuentas de Plata

El pipeline `plata` lee los estados de cuenta de Alpaca. Abre y cierra las
cuentas de cada commodity por sí mismo, con `"FIFO"`. No declares esas cuentas
en `account_opens.beancount`. Si una posición se cierra y vuelve a abrir en
un mes posterior, `bean-check` reporta una colisión. Borra el `close` anterior
y el `open` posterior.
