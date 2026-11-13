# Las reglas

Una regla clasifica una transacción por su descripción. Le pone un `payee`,
una `narration` y una cuenta de gastos o ingresos. Una transacción sin regla
queda en `Expenses:FIXME`, y la página del estado de cuenta la marca como
"sin clasificar". El botón "Revisar", junto al título, dice cuántas faltan y
abre Revisar (ver
[Revisar los movimientos sin clasificar](#revisar-los-movimientos-sin-clasificar)).

Solo las cuentas de los pipelines Default y Multi usan reglas. Las cuentas de
CetesDirecto, Fintual y Alpaca no tienen archivo de reglas ni editor.

## El archivo

Cada cuenta tiene un archivo, `config/rules/<Key>.yaml`, en el ledger. La
clave es la misma de `accounts.yaml`, con espacios:
`config/rules/BBVA TDC.yaml`.

```yaml
start_with:
  # La descripción empieza con el patrón.
  AMAZON WEB SERVICES:
    payee: Amazon
    narration: AWS
    account: Expenses:Subscriptions

  # `when` agrega una condición: el monto exacto.
  NETFLIX:
    when:
      amount: -149
    payee: Netflix
    account: Expenses:Subscriptions

  # Una lista prueba cada `when` en orden. La entrada sin `when` es la de respaldo.
  TRANSFERENCIA:
    - when:
        amount: -15000
      payee: Landlord
      narration: Rent
      account: Expenses:Housing:Rent
    - payee: Transfer
      account: Expenses:Misc

include:
  # La descripción contiene el patrón en cualquier parte.
  GROCERY:
    account: Expenses:Food:Groceries
```

Hay dos secciones. `start_with` compara el inicio de la descripción.
`include` busca el patrón en toda la descripción. Cada entrada puede llevar
`payee`, `narration` y `account`. Los tres son opcionales.

La app aplica todas las reglas que coinciden, en este orden: las de
`start_with` en el orden del archivo, y después las de `include`. Una regla
posterior sobrescribe solo los campos que define. Así, una regla de `include`
puede poner la cuenta y dejar el `payee` de una regla de `start_with`.

La única condición es `when.amount`. Compara el monto exacto, con signo. Un
cargo es negativo.

## Transferencias entre tus cuentas

Un pago de BBVA a tu tarjeta Amex aparece en los dos estados de cuenta: como
cargo en BBVA y como abono en Amex. Si la regla de cada lado apunta a la otra
cuenta, el pago queda dos veces en el ledger. Por eso, las reglas de los dos
lados apuntan a `Assets:Transfers`:

```yaml
# config/rules/BBVA.yaml
start_with:
  AMERICAN EXPRESS:
    narration: Pago TDC Amex
    account: Assets:Transfers

# config/rules/AMEX.yaml
start_with:
  PAGO RECIBIDO, GRACIAS:
    narration: Pago TDC Amex
    account: Assets:Transfers
```

El cargo de BBVA mete el dinero a `Assets:Transfers` y el abono de Amex lo
saca. Cuando los dos estados de cuenta están en el ledger, la cuenta queda en
cero. Cada estado de cuenta conserva todos sus movimientos, igual que el PDF, y
no hay nada que borrar a mano.

Si la cuenta no queda en cero, a una transferencia le falta un lado: el otro
estado de cuenta todavía no llega, o los montos no son iguales. Recientes lo
dice con "Transferencias sin pareja" y lleva al diario de la cuenta. Ahí el
saldo después de cada movimiento muestra cuál es.

- Una cuenta de inversión (CetesDirecto, Fintual) no tiene reglas. Su
  `counterpart_account` en `accounts.yaml` es `Assets:Transfers`.
- Un pago a una cuenta de la que no subes estados de cuenta, como un crédito,
  apunta a esa cuenta. Ahí no hay un segundo lado.
- Las dos partes deben estar en la misma moneda.
- Un ledger nuevo ya abre `Assets:Transfers`. En un ledger anterior, agrega
  `2000-01-01 open Assets:Transfers` junto a tus otros `open`.

## Cuándo corren las reglas

La corrida aplica las reglas una vez, después de la extracción y antes de
escribir el archivo `.beancount`. Si la cuenta no tiene archivo de reglas, la
corrida no aplica nada.

El botón "Aplicar reglas", en Revisar, las aplica otra vez sobre el archivo
`.beancount`. El botón aparece solo cuando queda algo sin clasificar y la
cuenta tiene archivo de reglas. Ese paso toca solo las
transacciones que siguen en `Expenses:FIXME`, así que una edición a mano no
cambia. Las reglas no ven una transacción con la bandera `!`. Si algo cambió,
la app hace commit.

## El editor

La pestaña Reglas de la cuenta (`/accounts/<Key>/rules`) edita el archivo
completo. "Cómo escribir reglas" abre un resumen de este formato. El editor
tiene números de línea y colores.

Después de `account:`, el editor completa los nombres de las cuentas abiertas
del ledger. Escribe dos letras o más de la cuenta y presiona Tab para tomar la
primera sugerencia.

Al guardar, la app valida el YAML y prueba el archivo con el motor de reglas.
Si el archivo es inválido, la app no lo guarda y muestra el error. Si es
válido, la app hace commit con el mensaje `rules <Key>`.

## Revisar los movimientos sin clasificar

Revisar muestra los movimientos sin clasificar de un estado de cuenta en un
solo formulario. Es la forma rápida de clasificar muchos movimientos.

1. En el estado de cuenta, presiona "Revisar".
2. Revisa la cuenta de cada movimiento. La app ya llenó la que adivinó (ver
   [Cuentas sugeridas](#cuentas-sugeridas)). Si no es la correcta, presiona
   otra de las sugeridas o escribe la cuenta. Al escribir, la app sugiere las
   cuentas abiertas del ledger.
3. Si quieres, cambia el payee y la narración.
4. Si el comercio se repite, marca "Regla". Abajo aparece el patrón: la
   descripción sin el RFC, la referencia ni el monto en dólares. Si es
   necesario, acórtalo.
5. Presiona "Guardar" o ⌘↩.

Lo que dejas vacío queda sin clasificar. Así, un cargo de Amazon puede esperar
hasta que lo revises en Amazon.

Al guardar, la app clasifica cada movimiento que llenaste y agrega las reglas
nuevas al final de `start_with`. Después aplica las reglas de la cuenta, las
viejas y las nuevas, a los movimientos que dejaste vacíos. Luego revisa el
ledger una vez y hace un solo commit, `Revisión <Key> YYMM`.

Si una fila tiene un error, como una cuenta que no existe, la app no guarda
nada. Marca la fila con el error y conserva lo que escribiste. Si el estado de
cuenta cambió mientras lo revisabas, por una corrida o un pull, la app no
guarda nada y muestra los movimientos otra vez, como una página nueva.

### Cuentas sugeridas

Al terminar cada corrida, la app pide al modelo tres cuentas para cada
movimiento sin clasificar. El modelo ve los cinco movimientos pasados del
ledger que más se parecen y la cuenta que elegiste para cada uno. Revisar
llena la cuenta con la primera y muestra las otras dos abajo, en "Otras". Si
presionas una, pasa al campo. Guardar guarda lo
que dicen los campos: una sugerida que no cambias se guarda igual que una que
escribes.

- Un movimiento que una regla toca pero sin `account`, como Amazon, no tiene
  sugerencia, porque lo revisas en otro lado.
- En las pruebas con los estados de cuenta de 2026, la primera sugerida fue
  la correcta en 64 % de los movimientos, y una de las tres en 78 %. Un estado
  de cuenta de 36 movimientos cuesta cerca de 0.01 USD, y cuenta en el límite
  del mes.
- Si un estado de cuenta no tiene sugerencias, porque se procesó antes o
  porque falló la llamada, Revisar muestra "Sugerir cuentas". El botón crea
  una corrida, y al terminar la corrida lleva de vuelta a Revisar.

## Hacer una regla desde un movimiento

1. Abre el estado de cuenta.
2. En un movimiento sin clasificar, presiona "Hacer regla".
3. Llena `payee`, `narration` y `account`.
4. Si la descripción trae datos que cambian, como una fecha o un folio, acorta
   el patrón.
5. Presiona "Guardar". La app abre Revisar.
6. Presiona "Aplicar reglas".

"Hacer regla" agrega una entrada al final de `start_with`, con la descripción
como patrón. El cursor queda después de `account:`. El resto del archivo no
cambia, con sus comentarios y su orden. Si el patrón ya existe, el editor abre
el archivo sin cambios. Un campo vacío no cambia nada: un `payee` vacío deja
el de la transacción. Al guardar, la app vuelve a Revisar el estado de cuenta.

## Clasificar un movimiento sin regla

Un movimiento que no se repite no necesita una regla.

1. En la vista Ver del estado de cuenta, presiona la fecha del
   movimiento.
2. En el editor, cambia `Expenses:FIXME` por la cuenta.
3. Presiona "Guardar".

Antes de guardar, la app revisa el ledger. Si el cambio agrega errores, la app
no lo guarda y marca las líneas con error. Si no, guarda el archivo y hace
commit.
