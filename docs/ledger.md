# El ledger

El ledger es tu repo de git, privado. Guarda las transacciones, la
configuración de las cuentas, las reglas y los prompts. La app lee la
configuración en cada request y en cada corrida, así que un cambio en el
ledger no necesita un deploy.

## Las tres copias

| Copia | Dónde | Quién escribe |
|---|---|---|
| Laptop | Tu clon en la laptop | Tú, a mano. Haz pull con rebase antes de cada push. |
| Servidor | `/data/ledger` en el contenedor | La app. Cada corrida hace pull con rebase al empezar, y commit y push al terminar. Los editores de la app hacen commit y push al guardar. |
| GitHub | origin | Nadie de forma directa. |

Antes de cada push, la app hace pull con rebase otra vez. Así integra lo que
llegó mientras la corrida trabajaba. Si el rebase encuentra un conflicto, la
app lo aborta y la corrida falla. El commit se queda en el servidor.

## Crear un ledger

1. Corre `bin/new-ledger <directorio>`.
2. Para el servidor, crea un repo privado en GitHub.
3. Agrega el remoto y haz push:

   ```bash
   git -C <directorio> remote add origin git@github.com:<usuario>/<repo>.git
   git -C <directorio> push -u origin main
   ```

4. En la laptop, pon la ruta en `LEDGER_REPO` de `.env`.
5. En el servidor, clona el repo en `/data/ledger`.
6. Abre `/accounts/new` y da de alta la primera cuenta.

`bin/new-ledger` crea los archivos iniciales, copia los prompts y hace el
primer commit. Con eso ya puedes correr la app en la laptop. Sobre un ledger
que ya existe, el mismo script agrega solo lo que falta (ver
[setup.md](setup.md#si-ya-tienes-un-ledger)).

Con un remoto, cada corrida hace `git pull --rebase` al empezar y `git push`
al terminar. Sin remoto, la corrida no hace ninguno de los dos, y cada commit
se queda en tu clon.

## El layout del repo

```
main.beancount                # el archivo principal: las opciones, los opens y un include por estado de cuenta
config/accounts.yaml          # las cuentas
config/rules/<Key>.yaml       # las reglas, un archivo por cuenta
config/prompts/<tipo>/        # spec.json, instructions.txt y schema.json
accounts/<Key>/<Key> YYMM.beancount   # un estado de cuenta, con su .json al lado
```

El nombre de un estado de cuenta es la clave de la cuenta, un espacio y el
periodo como `YYMM`. El periodo es el mes que tiene la mayoría de los días del
estado de cuenta. Un estado de AMEX del 4 de agosto al 3 de septiembre es
`2608`.

`main.beancount` es el único archivo que la app conoce por nombre
(`LEDGER_MAIN_FILE` lo cambia). La app le agrega un `open` cuando das de alta
una cuenta, y un `include` cuando procesa un estado de cuenta. Si el repo
tiene un `account_opens.beancount`, los `open` van ahí.

Los reportes leen el archivo principal con rustledger. Las transacciones
sueltas, los precios y las aserciones de saldo pueden ir ahí o en archivos
aparte con su propio `include`. A Beancount no le importa en qué archivo está
cada entrada.

Si el archivo principal tiene `option "title"`, la app muestra ese nombre en
cada página. Si no, muestra Frijolero.

En el bucket, los PDF viven en `frijolero/accounts/<Key>/<Key> YYMM.pdf`. Todo
va bajo el prefijo `frijolero/`, así que otras apps pueden usar el mismo
bucket.

## config/accounts.yaml

Cada bloque es una cuenta. La clave es el nombre del directorio en
`accounts/` y el prefijo de cada archivo de esa cuenta.

```yaml
AMEX:
  beancount_account: "Liabilities:AMEX"
  openai_prompt_type: default
  description: "Amex credit card (tarjeta de crédito), MXN"
  cutoff_day: 3

Alpaca:
  beancount_account: "Assets:Investments:Alpaca"
  openai_prompt_type: alpaca
  converter_type: alpaca
  dividend_account: "Income:Dividends:Alpaca"
  payee: "Mi asesor"

Plata Banco:
  beancount_account: "Assets:Plata:Cuenta"
  openai_prompt_type: multi
  converter_type: multi
  accounts:
    Plata Cuenta: "Assets:Plata:Cuenta"
    Ahorro Flexible: "Assets:Plata:Ahorro"

Old Card:
  beancount_account: "Liabilities:OldCard"
  openai_prompt_type: default
  closed: true
```

| Campo | Uso |
|---|---|
| `beancount_account` | La cuenta de Beancount donde la app registra las transacciones. |
| `openai_prompt_type` | El directorio de `config/prompts/` que extrae este tipo de estado de cuenta. |
| `converter_type` | El pipeline: `cetes_directo`, `fintual`, `alpaca` (o `plata`, su nombre viejo) o `multi`. Sin este campo, el pipeline es Default. Solo Default y Multi usan reglas. |
| `accounts` | Solo Multi. Mapea cada nombre impreso a su cuenta de Beancount (ver la sección de Multi). |
| `description` | La pista que recibe el clasificador. Si falta, el clasificador usa la clave. |
| `cutoff_day` | El día del mes en que cierra el estado de cuenta. Sin este campo, el último día del mes. La corrida lo llena la primera vez que ve un periodo impreso, y nunca lo sobrescribe. |
| `closed` | Con `true`, la cuenta sale de Recientes y del clasificador. Su historial sigue en su página, en Cuentas. |

Un estado de cuenta que cierra en `cutoff_day` pertenece al mes de 15 días
antes del cierre. Recientes y el clasificador usan la misma regla.

Los pipelines CetesDirecto, Fintual y Alpaca registran intereses, impuestos y
ganancias en otras cuentas. Los campos que siguen nombran esas cuentas. Cada
uno es opcional. Sin él, la transacción va a `Income:FIXME` o
`Expenses:FIXME`.

| Campo | Pipelines | Uso |
|---|---|---|
| `counterpart_account` | CetesDirecto, Fintual | La cuenta de donde sale el efectivo y a donde vuelve. Por ejemplo, tu cuenta de banco. |
| `interest_account` | Los tres | Intereses. |
| `tax_account` | CetesDirecto, Fintual | El ISR retenido. |
| `gains_account` | Los tres | Ganancias y pérdidas de capital. |
| `dividend_account` | Fintual, Alpaca | Dividendos. |
| `fees_account` | Alpaca | Comisiones. |
| `withholding_account` | Alpaca | El impuesto retenido en el extranjero. |
| `opening_account` | Alpaca | La contraparte de una posición transferida desde otro broker. |
| `payee` | Alpaca | El nombre en cada transacción. Sin él, `Alpaca`. |

### Editar las cuentas

- La pestaña Configuración de una cuenta (`/accounts/<Key>/config`) edita
  solo el bloque de esa cuenta. Los comentarios del resto del archivo quedan
  igual.
- "Editar el archivo completo", en Cuentas (`/accounts/yaml`), edita todo
  `accounts.yaml`.
- "Nueva cuenta" (`/accounts/new`) da de alta una cuenta del pipeline Default.

Las cuentas de los otros pipelines necesitan más cuentas de Beancount. Dalas
de alta en el archivo completo. Los dos editores tienen números de línea y
completan los nombres de las cuentas abiertas del ledger.

### Multi

Multi lee un estado de cuenta que cubre varias cuentas del mismo banco, cada
una en su sección "Movimientos de <nombre>". `accounts` mapea cada nombre
impreso a una cuenta de Beancount. La app registra cada movimiento desde la
cuenta de su sección.

Un traspaso entre esas cuentas aparece dos veces, una vez por sección. Una
regla puede mandar un movimiento a la otra cuenta del mismo estado de cuenta.
Ese movimiento se queda, y la app descarta su espejo: el movimiento de la
otra cuenta con la misma fecha y el monto opuesto.

## config/prompts/\<tipo\>/

Cada `openai_prompt_type` apunta a un directorio con tres archivos:

- `spec.json`: el modelo y el formato de salida.
- `instructions.txt`: el prompt del sistema.
- `schema.json`: el esquema JSON estricto de la respuesta.

El modelo de `spec.json` debe ser del proveedor de `LLM_PROVIDER`:

| Proveedor | Extraer | Clasificar (`classify`) |
|---|---|---|
| `openai` | `gpt-5.6-sol` | `gpt-5.4-mini` |
| `anthropic` | `claude-opus-5` | `claude-haiku-4-5` |

Con `LLM_PROVIDER=anthropic`, `bin/new-ledger` pone los modelos de Anthropic.
Los demás campos de `spec.json` van tal cual a la API del proveedor.
`reasoning` es de OpenAI. `max_tokens`, `thinking` y `output_config` son de
Anthropic. El esquema es el mismo para los dos. Anthropic exige
`additionalProperties: false` en cada objeto, y los esquemas estrictos de
OpenAI ya lo traen.

El directorio `classify` tiene el prompt que lee la cuenta y el periodo de un
PDF subido. La app llena su lista de cuentas desde `accounts.yaml` en cada
llamada.

`templates/prompts/` de este repo tiene los cuatro prompts genéricos:
`classify`, `default`, `multi` y `alpaca`. `bin/new-ledger` los copia al
ledger, que tiene la copia viva. Un prompt para un banco en particular es un
directorio más en `config/prompts/` del ledger. La forma de cuenta nueva
ofrece esos directorios.

## Las cuentas de CETES Directo

El pipeline `cetes_directo` lleva cada instrumento en su propia subcuenta, con
`"FIFO"`: `Assets:Investments:CetesDirecto:CETES-280412`. El efectivo está en
`<cuenta>:Cash`. Declara esa cuenta en `account_opens.beancount`. El pipeline
abre y cierra las cuentas de los instrumentos.

- Un vencimiento registra como interés la diferencia contra el costo, igual
  que el estado de cuenta. Así, el interés de un año en el ledger es el
  "Intereses acumulados del ejercicio" del estado.
- El estado de resultados muestra solo lo realizado: cupones, vencimientos y
  ventas de BONDDIA. El cambio del valor de mercado aparece en el balance
  general, en "Ganancias no realizadas".
- La app escribe su lado de cada transferencia al banco, y el estado del banco
  tiene el otro lado. Borra uno. Si quedan los dos, falla el saldo de
  efectivo del mes.
- El primer estado de cuenta necesita una entrada de apertura con los títulos
  y su costo, porque la tabla de apertura no imprime el costo.

## Las cuentas de Alpaca

El pipeline `alpaca` lee los estados de cuenta mensuales de Alpaca, la casa de
bolsa detrás de varios asesores. El pipeline abre y cierra la cuenta de cada
commodity, con `"FIFO"`. No declares esas cuentas en
`account_opens.beancount`.

Una posición puede cerrarse y volver a abrirse en un mes posterior. En ese
caso, Beancount marca un error porque la cuenta se abre dos veces. Para
corregirlo, borra el `close` anterior y el `open` posterior.
