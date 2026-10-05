# Instalar, correr y desplegar

## Requisitos

- Ruby 4.0.6, la versión de `.ruby-version`.
- git. La app lo usa para el ledger.
- Una llave de OpenAI o de Anthropic, para clasificar y extraer.
- rustledger, para los reportes y la revisión de errores.

En la laptop, instala rustledger con `brew install rustledger`. La app busca
`rledger` en el PATH, o en la variable `RLEDGER`. Sin rustledger, los reportes
muestran el error y lo demás funciona.

## Correr en la laptop

1. Instala las gemas con `bundle install`.
2. Corre `bin/dev`.
3. Abre http://localhost:3000.
4. Escribe la contraseña `x`.
5. Presiona "Dar de alta una cuenta" y llena la forma.

`bin/dev` no necesita `.env`. La primera vez, crea un ledger en
`~/.local/share/frijolero/ledger` con `bin/new-ledger`. Ese ledger no tiene
remoto, así que cada commit se queda en él. Los PDF quedan en
`~/.local/share/frijolero/pdfs`.

### Extraer estados de cuenta

1. Copia `.env.example` a `.env`.
2. Pon tu llave de OpenAI en `OPENAI_API_KEY`.
3. Corre `bin/dev` otra vez.

Si prefieres Claude, pon `LLM_PROVIDER=anthropic` y `ANTHROPIC_API_KEY` en
lugar de `OPENAI_API_KEY`. El nombre del modelo va en cada `spec.json` del
ledger (ver [ledger.md](ledger.md#configpromptstipo)).

Cada PDF que subes cuesta una llamada al modelo para clasificarlo, salvo uno
que se llame `Clave YYMM.pdf`. Procesar cuesta la extracción y hace commit en
el ledger. Sin llave, la app no clasifica ni extrae: en la Bandeja solo guarda
el PDF, con la cuenta y el periodo que elijas.

### Si ya tienes un ledger

Un ledger de Beancount que ya existe sirve tal cual. Frijolero le agrega
`config/` y no toca lo demás.

1. Corre `bin/new-ledger <ruta de tu ledger>`.
2. Pon la ruta en `LEDGER_REPO` de `.env`.
3. Si tu archivo principal no se llama `main.beancount`, pon su nombre en
   `LEDGER_MAIN_FILE` de `.env`.
4. En Cuentas, da de alta cada cuenta que recibe estados de cuenta.

`bin/new-ledger` agrega lo que falta: `config/accounts.yaml`, `config/rules/`,
`config/prompts/` y `accounts/`. No cambia los archivos que ya existen. Si el
directorio no es un repo de git, hace `git init`. Al final hace un commit con
lo que agregó.

`bin/dev` enlaza tu ledger en `tmp/dev/ledger`. El log de corridas, los PDF y
las subidas quedan en `tmp/dev`, no junto a tu ledger. Si no encuentra el
archivo principal, `bin/dev` se detiene y lista los archivos `.beancount` que
ve.

En la forma de cuenta nueva, el campo de la cuenta Beancount ofrece las
cuentas de activo y pasivo que tu ledger ya abre. Si el ledger todavía no
tiene `config/prompts/`, la forma lo dice y el botón "Crear" está apagado.

### Un ledger de demostración

`bin/demo-ledger <dir>` crea un ledger inventado para enseñar la app sin
enseñar tus finanzas. Tiene tres cuentas en bancos con nombres de dioses
griegos y dos años de estados de cuenta. También trae reglas, aserciones de
saldo, PDF de relleno y una bitácora.

Las opciones `--persona employee|contractor`, `--income`, `--months` y
`--seed` cambian la historia. El script imprime la semilla al terminar. La
misma semilla da el mismo ledger. Para verlo, corre
`LEDGER_DIR=<dir>/ledger bin/dev`.

### Los PDF en un bucket

Para guardar los PDF en un bucket, llena las cuatro variables `S3_*` de
`.env`. Sirve cualquier almacenamiento compatible con S3: Backblaze B2, AWS,
Cloudflare R2, Hetzner, DigitalOcean Spaces o MinIO. Si llenas solo algunas,
la página de la cuenta dice cuáles faltan.

## Variables de entorno

| Variable | Uso |
|---|---|
| `LEDGER_DIR` | El clon del ledger. Obligatoria. El directorio padre guarda el log de corridas y las subidas. `bin/dev` la pone por ti. |
| `LEDGER_MAIN_FILE` | El archivo principal del ledger, relativo a `LEDGER_DIR`. Por defecto, `main.beancount`. |
| `APP_PASSWORD` | La contraseña. Obligatoria. También firma la cookie de sesión, que dura 30 días. Si la cambias, todos los dispositivos cierran sesión. |
| `API_TOKEN` | El token del atajo de iOS (ver [Subir desde el iPhone](#subir-desde-el-iphone)). Solo abre `/api/upload`. Sin él, `/api/` está cerrado. |
| `LLM_PROVIDER` | El proveedor del modelo: `openai` (por defecto) o `anthropic`. |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` | La llave del proveedor. Sin ella, la app no clasifica ni extrae: solo guarda los PDF. |
| `LLM_TIMEOUT` | Los segundos que la app espera al modelo en una extracción. Por defecto, 900. |
| `S3_ENDPOINT`, `S3_BUCKET`, `S3_KEY_ID`, `S3_KEY` | Un bucket compatible con S3 para los PDF. El endpoint es el host, sin `https://`. Sin las cuatro, los PDF quedan en `pdfs/`, junto al ledger. |
| `S3_REGION` | La región para la firma. Por defecto, el segundo segmento del endpoint, que es lo que esperan B2 y AWS (`s3.us-west-000.backblazeb2.com`). R2 usa `auto`, Hetzner su ubicación (`fsn1`), DigitalOcean y MinIO `us-east-1`. |
| `S3_PATH_STYLE` | Con `1`, el bucket va en la ruta (`endpoint/bucket/llave`) y no en el host (`bucket.endpoint/llave`). Sirve para MinIO en localhost o para un bucket con punto en el nombre. |
| `GIT_TOKEN` | Un token fine-grained de GitHub con permiso de lectura y escritura de contenido en el repo del ledger. Viaja como header HTTP en cada llamada a git. Nunca se escribe en disco. |
| `PUMA_THREADS` | El número de threads. En producción, 3. |
| `RLEDGER` | El binario de rustledger. Por defecto, `rledger` en el PATH. |

## Desplegar

La app corre en un servidor con Kamal 2. `config/deploy.yml` es el deploy del
autor: el servidor, el host, la imagen, el volumen `/data` y el límite de
memoria. Para tu copia, cambia los valores que nombra el comentario al inicio
de ese archivo. Kamal construye la imagen en tu máquina, para amd64, y la
sube a un registro de contenedores.

`.kamal/secrets` pide los secretos a 1Password con el CLI `op` en cada
deploy. Para tu copia, cambia la cuenta y el item, o usa otro adaptador de
Kamal. Nada secreto vive en el repo.

La imagen usa la zona horaria de la Ciudad de México (`TZ` en el
`Dockerfile`). La Bitácora muestra las horas en esa zona, y "hoy" cambia a la
medianoche de esa zona. Para otra zona, cambia `TZ`.

Para desplegar:

1. Desbloquea la app de 1Password.
2. Corre `kamal deploy`.

Un deploy tarda unos 40 segundos. Si un deploy falla y deja un lock, corre
`kamal lock release`.

La primera vez:

1. Clona el repo del ledger en `/data/ledger`, dentro del volumen del
   servidor.
2. Corre `kamal setup` en lugar de `kamal deploy`.

Para correr un comando en el contenedor de producción:

```bash
kamal app exec --reuse '<comando>'
```

### Qué necesita un deploy

Un cambio en el código de la app necesita un deploy. Un cambio en las reglas,
las cuentas, los prompts o el modelo es un commit en el ledger. La app lee
esos archivos en cada request y en cada corrida.

El servidor recibe un commit del ledger en la siguiente corrida. El botón
"Actualizar" de los reportes lo trae de inmediato. Este comando hace lo
mismo:

```bash
kamal app exec --reuse 'bundle exec ruby -Ilib -e "require %q(frijolero); Frijolero::LedgerRepo.new(dir: ENV.fetch(%q(LEDGER_DIR))).pull"'
```

### La imagen en la laptop

Con Docker no necesitas Ruby. El contenedor corre como el usuario `app`. El
directorio que montas en `/data` debe ser de ese usuario, o estar abierto a
todos. Si `/data/ledger` no existe, créalo antes con `bin/new-ledger`.

```bash
docker build -t frijolero .
mkdir -p ~/.local/share/frijolero && chmod 777 ~/.local/share/frijolero
docker run --rm -p 9292:9292 -v ~/.local/share/frijolero:/data \
  -e APP_PASSWORD=x -e LEDGER_DIR=/data/ledger -e OPENAI_API_KEY=... frijolero
```

## Subir desde el iPhone

Un atajo de iOS manda un PDF desde la hoja de compartir de otra app, por
ejemplo la app de tu banco. El PDF espera en la Bandeja hasta que lo
confirmas. La app no procesa nada sin tu confirmación.

1. Crea un token con `openssl rand -hex 32`.
2. Ponlo en `API_TOKEN`. En producción, ponlo en el campo `api_token` del
   item de 1Password antes del deploy. Sin ese campo, el deploy falla.
3. En la app Atajos, crea un atajo que recibe PDF de la hoja de compartir.
   Para cada PDF, el atajo hace este request con la acción "Obtener
   contenido de URL" (Get Contents of URL):

   ```
   POST https://<tu host>/api/upload
   Authorization: Bearer <tu token>
   Cuerpo: formulario, con el PDF en un campo de tipo archivo llamado pdf
   ```

4. Al final, el atajo abre `https://<tu host>/inbox`.

La respuesta siempre es JSON, porque al atajo le cuesta leer el status:

- `202` y `{"inbox": "https://…/inbox"}`: el PDF está en la Bandeja.
- `401` y `{"error": "Token inválido"}`: falta el token o no es correcto.
- `422` y `{"error": "…"}`: el archivo no es un PDF, o no hay cuentas.

Para ver los errores en el teléfono, toma el valor `error` del diccionario.
Si tiene valor, muestra una alerta con él.

La Bandeja clasifica cada PDF en segundo plano y se actualiza sola mientras
clasifica. Junto a cada PDF muestra la cuenta y el periodo que encontró, y
puedes cambiarlos. "Procesar los listos" procesa los PDF marcados con
● listo. Un PDF con ▲ o ■ necesita tu revisión: no se identificó, ya existe,
está repetido en la Bandeja, no se clasificó o su corrida falló. Descartar
borra el PDF.

## Una corrida que falla

La página de la corrida muestra el error y la salida completa. En Recientes,
"falló" lleva a esa página. El PDF se queda en `/data/incoming/<hex>/`. Si
el PDF sigue ahí, la subida también vuelve a la Bandeja con "■ falló", con la
cuenta y el periodo que elegiste. Procesar la corre otra vez.

Si la corrida falló en la extracción, por ejemplo por el límite de uso del
modelo, la página muestra "Reintentar". El botón corre la misma subida otra
vez, sin subir el PDF de nuevo. Aparece solo con estas condiciones:

- El PDF sigue en el servidor.
- La cuenta existe.
- La app tiene la llave del modelo.
- Ese estado de cuenta todavía no existe.

Si no aparece, sube el PDF otra vez. En la Bandeja, Descartar borra una
subida que ya no sirve. Una corrida que falla después de la extracción ya no
tiene el PDF. Su directorio se queda, y nada lo borra.
