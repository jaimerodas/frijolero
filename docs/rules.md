# Las reglas

Una regla clasifica una transacción por su descripción. Le pone un `payee`,
una `narration` y una cuenta de gastos o ingresos. Una transacción sin regla
queda en `Expenses:FIXME`, y la página del estado de cuenta la marca como
"sin clasificar".

Solo las cuentas del pipeline Default usan reglas. Las cuentas de CetesDirecto,
Fintual y Plata no tienen archivo de reglas ni editor.

## El archivo

Cada cuenta tiene un archivo, `config/rules/<Key>.yaml`, en el repo del
ledger. La clave es la misma de `accounts.yaml`, con espacios:
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
posterior sobreescribe solo los campos que define. Así una regla de `include`
puede poner la cuenta y dejar el `payee` de una regla de `start_with`.

La única condición es `when.amount`. Compara el monto exacto, con signo. Un
cargo es negativo.

## Cuándo corren las reglas

El job las aplica una vez, después de la extracción y antes de escribir el
archivo `.beancount`. Si la cuenta no tiene archivo de reglas, el job no
aplica nada.

El botón "Volver a correr las reglas" de la página del estado de cuenta las
aplica otra vez sobre el archivo `.beancount` que ya existe. Ese paso toca
solo las transacciones que siguen en `Expenses:FIXME`. Una transacción que ya
tiene cuenta no cambia, así una edición a mano está a salvo. Una transacción
con la bandera `!` es invisible para las reglas. Si algo cambió, la app hace
commit. Si no, no.

## El editor

`/accounts/<Key>/rules` edita el archivo completo. Al guardar, la app valida el YAML y
prueba una llamada al motor de reglas. Un archivo inválido no se guarda. Un
archivo válido se guarda con el commit `rules <Key>`.

## Hacer una regla desde una transacción

1. Abre el estado de cuenta.
2. En una transacción sin clasificar, presiona "Hacer regla". El editor abre
   con una entrada nueva de `start_with`, con la descripción como patrón.
3. Ajusta el patrón, el `payee`, la `narration` y la cuenta.
4. Presiona "Guardar". La app vuelve al estado de cuenta.
5. Presiona "Volver a correr las reglas".

"Hacer regla" reescribe el archivo completo con `YAML.dump`. Ese paso borra
los comentarios y reordena las llaves. Es visible en un archivo largo.
