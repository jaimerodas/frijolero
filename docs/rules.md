# Las reglas

Una regla clasifica una transacción por su descripción. Le pone un `payee`,
una `narration` y una cuenta de gastos o ingresos. Una transacción sin regla
queda en `Expenses:FIXME`, y la página del estado de cuenta la marca como
"sin clasificar". "▲ N sin clasificar", arriba de la lista, muestra solo los
movimientos sin clasificar. "Ver todos" muestra la lista completa otra vez.

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

## Cuándo corren las reglas

La corrida aplica las reglas una vez, después de la extracción y antes de
escribir el archivo `.beancount`. Si la cuenta no tiene archivo de reglas, la
corrida no aplica nada.

El botón "Aplicar reglas" de la página del estado de cuenta las aplica otra
vez sobre el archivo `.beancount`. El botón aparece solo cuando queda algo sin
clasificar y la cuenta tiene archivo de reglas. Ese paso toca solo las
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

## Hacer una regla desde un movimiento

1. Abre el estado de cuenta.
2. En un movimiento sin clasificar, presiona "Hacer regla".
3. Llena `payee`, `narration` y `account`.
4. Si la descripción trae datos que cambian, como una fecha o un folio, acorta
   el patrón.
5. Presiona "Guardar".
6. En el estado de cuenta, presiona "Aplicar reglas".

"Hacer regla" agrega una entrada al final de `start_with`, con la descripción
como patrón. El cursor queda después de `account:`. El resto del archivo no
cambia, con sus comentarios y su orden. Si el patrón ya existe, el editor abre
el archivo sin cambios. Un campo vacío no cambia nada: un `payee` vacío deja
el de la transacción. Al guardar, la app vuelve al estado de cuenta.

## Clasificar un movimiento sin regla

Un movimiento que no se repite no necesita una regla.

1. En la vista Movimientos del estado de cuenta, presiona la fecha del
   movimiento.
2. En el editor, cambia `Expenses:FIXME` por la cuenta.
3. Presiona "Guardar".

Antes de guardar, la app revisa el ledger. Si el cambio agrega errores, la app
no lo guarda y marca las líneas con error. Si no, guarda el archivo y hace
commit.
