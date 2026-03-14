# Migrar transacciones inline a include

El archivo principal de beancount puede contener transacciones inline de antes del cambio a `include`. Este documento describe cómo migrarlas.

## Formato anterior

Las transacciones se agregaban directamente al archivo principal, delimitadas por marcadores:

```
; === Start: Amex_2501.beancount ===

2025-01-15 * "Payee" "Narration"
  Liabilities:Amex  -50.00 MXN
  Expenses:Category

; === End: Amex_2501.beancount ===
```

## Pasos para migrar

1. Parsear el archivo principal buscando bloques `Start/End`
2. Extraer el nombre del archivo del marcador (e.g., `Amex_2501.beancount`)
3. Usar `AccountConfig.parse_filename` para obtener el prefijo (e.g., `"Amex"`)
4. Escribir el contenido a `transactions/<prefijo>/<archivo>.beancount`
5. Reemplazar el bloque con `include "transactions/<prefijo>/<archivo>.beancount"`

## Regex para encontrar bloques

```ruby
/^; === Start: (.+?) ===\n(.+?)^; === End: \1 ===\n/m
```

- `$1` = nombre del archivo (e.g., `Amex_2501.beancount`)
- `$2` = contenido de las transacciones
