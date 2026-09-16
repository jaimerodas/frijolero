# Instalar, correr y desplegar

## Requisitos

- Ruby 4.0.6. La versión está en `.ruby-version`.
- git. La app lo usa como subproceso para el ledger.
- Una llave de OpenAI o de Anthropic. La extracción es lo que hace la app.
- rustledger, solo para los reportes. En la laptop: `brew install rustledger`.
  La app busca `rledger` en el PATH, o en la variable `RLEDGER`. Sin él, todo
  lo demás funciona y la página de reportes muestra el error.

## Correr en la laptop

1. Instala las gemas con `bundle install`.
2. Corre `bin/dev`. No necesita `.env` para arrancar. La primera vez crea un ledger en
   `~/.local/share/frijolero/ledger` con `bin/new-ledger`. Ese ledger no tiene
   remoto: cada commit se queda ahí, y los PDF quedan en
   `~/.local/share/frijolero/pdfs`.
3. Abre http://localhost:3000. La página te pide la contraseña en un formulario. La contraseña es `x`.
4. Da de alta la primera cuenta en Cuentas.
5. Para subir un estado de cuenta, copia `.env.example` a `.env`, pon
   `OPENAI_API_KEY` y vuelve a correr `bin/dev`. Una subida gasta dinero y
   hace commit al ledger. Sin la llave, la página de subir lo dice: la app
   solo guarda un PDF llamado `Clave YYMM.pdf` y no extrae nada. Para usar
   Claude en lugar de OpenAI, pon `LLM_PROVIDER=anthropic` y
   `ANTHROPIC_API_KEY`; el modelo va en cada `spec.json` del ledger (ver
   `docs/ledger.md`).

### Si ya tienes un ledger

Un ledger de Beancount que ya existe sirve tal cual. Frijolero le agrega
`config/` y no toca lo demás.

1. Corre `bin/new-ledger <ruta de tu ledger>`. Agrega lo que falte:
   `config/accounts.yaml`, `config/rules/`, `config/prompts/` y `accounts/`.
   No toca ningún archivo que ya está. Si el directorio no es un repo de git,
   hace `git init`. Hace un commit con lo que agregó.
2. Pon la ruta en `LEDGER_REPO` de `.env`. `bin/dev` la enlaza en
   `tmp/dev/ledger`, y el log de jobs, los PDF y las subidas quedan en
   `tmp/dev`, no junto al repo del ledger.
3. Si tu archivo principal no se llama `main.beancount`, pon su nombre en
   `LEDGER_MAIN_FILE` de `.env`. Sin eso, `bin/dev` se detiene y lista los
   archivos `.beancount` que ve.
4. Da de alta cada cuenta que recibe estados de cuenta en Cuentas. El campo
   de la cuenta Beancount ofrece las cuentas de activo y pasivo que tu ledger
   ya abre.

Si abres Cuentas antes del paso 1, la página lo dice y el botón de crear
está apagado.

Para enseñar la app sin enseñar tus finanzas, `bin/demo-ledger <dir>` crea un
ledger inventado: tres cuentas en bancos con nombres de dioses griegos, dos
años de estados de cuenta, reglas, aserciones de saldo, PDFs de relleno y una
bitácora. `--persona employee|contractor`, `--income`, `--months` y `--seed`
cambian la historia; el script imprime la semilla al terminar, y con `--seed` la
misma semilla repite el mismo ledger. Cada estado de cuenta pasa por el mismo
pipeline que un job real. Para verlo: `LEDGER_DIR=<dir>/ledger bin/dev`.

Si quieres los PDF en un bucket en lugar del disco, llena las cuatro
variables `S3_*` en `.env`. Sirve cualquier almacenamiento compatible con S3:
Backblaze B2, AWS, Cloudflare R2, Hetzner, DigitalOcean Spaces, MinIO. Con una
sola de ellas puesta, la app asume que quieres el bucket y la página de la
cuenta nombra las que faltan.

La ruta `/up`, `/login` y los archivos estáticos (`/style.css`, `/reports.js`)
responden sin necesidad de la cookie de sesión.

## Variables de entorno

| Variable | Uso |
|---|---|
| `LEDGER_DIR` | El clon del ledger. Obligatoria. El directorio padre guarda el log de jobs y las subidas. |
| `LEDGER_MAIN_FILE` | El archivo principal del ledger, relativo a `LEDGER_DIR`. Por defecto, `main.beancount`. Es el único archivo que la app conoce por nombre. |
| `APP_PASSWORD` | La única credencial. Se verifica en el formulario de login y firma la cookie de sesión que dura 30 días. Cambiar la contraseña cierra todas las sesiones en todos los dispositivos. Obligatoria. |
| `LLM_PROVIDER` | Quién extrae: `openai` (por defecto) o `anthropic`. |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` | La llave del proveedor elegido. Sin ella, la app solo acepta PDF llamados `Clave YYMM.pdf` y no extrae. |
| `LLM_TIMEOUT` | Segundos de espera para una extracción. Por defecto, 900. |
| `S3_ENDPOINT`, `S3_BUCKET`, `S3_KEY_ID`, `S3_KEY` | Un bucket compatible con S3. Los PDF viven ahí. El endpoint es el host, sin `https://`. Sin las cuatro, viven en `pdfs/` junto al ledger y la app los sirve en `/pdfs/`. |
| `S3_REGION` | La región para la firma. Sin ella, la app la toma del segundo segmento del endpoint, que es lo que B2 y AWS esperan (`s3.us-west-000.backblazeb2.com`). R2 quiere `auto`, Hetzner su ubicación (`fsn1`), DigitalOcean y MinIO `us-east-1`. |
| `S3_PATH_STYLE` | `1` pone el bucket en la ruta (`endpoint/bucket/llave`) en lugar del host (`bucket.endpoint/llave`). Para MinIO en localhost o un bucket con punto en el nombre. |
| `GIT_TOKEN` | Un token fine-grained de GitHub con permiso de lectura y escritura de contenido en el repo del ledger. Viaja como header HTTP en cada llamada a git. Nunca se escribe en disco. |
| `PUMA_THREADS` | El tamaño del pool de threads. En producción, 3. |
| `RLEDGER` | El binario de rustledger. Por defecto, `rledger` en el PATH. |

Si una llave de S3 trae un espacio, la app lo quita. Un espacio en 1Password
produjo una vez el error `Signature validation failed`.

## Desplegar

La app corre en un servidor con Kamal 2. `config/deploy.yml` es el deploy del
autor: el servidor, el host, la imagen, el volumen `/data` y el límite de
memoria. Para tu copia, cambia los valores que nombra el comentario al inicio
del archivo. La imagen se construye en tu máquina para amd64 y se sube a un
registro de contenedores.

`.kamal/secrets` pide los secretos a 1Password con el CLI `op` en cada deploy.
Cambia la cuenta y el item, o usa otro adaptador de Kamal. Nada secreto vive
en el repo.

1. Desbloquea la app de 1Password.
2. Corre `kamal deploy`.

Un deploy tarda unos 40 segundos. Si un deploy falla y deja un lock, corre
`kamal lock release`.

La primera vez, corre `kamal setup` en lugar de `kamal deploy`. Antes, clona
el repo del ledger en `/data/ledger` dentro del volumen del servidor.

Para correr un comando en el contenedor de producción:

```bash
kamal app exec --reuse '<comando>'
```

### Qué necesita un deploy y qué no

Un cambio en el código de esta app necesita un deploy. Un cambio en las
reglas, en las cuentas, en los prompts o en el modelo es un commit
en el repo del ledger. La app lee esos archivos en cada request y en cada job.
El servidor recibe el cambio en el siguiente job, o de inmediato con este
comando:

```bash
kamal app exec --reuse 'bundle exec ruby -Ilib -e "require %q(frijolero); Frijolero::LedgerRepo.new(dir: ENV.fetch(%q(LEDGER_DIR))).pull"'
```

El botón "Actualizar" de los reportes hace lo mismo.

### La imagen en la laptop

Con Docker no necesitas Ruby. El contenedor corre como el usuario `app`, así
que el directorio que montas en `/data` tiene que ser suyo o abierto a todos.
Si `/data/ledger` no existe, créalo antes con `bin/new-ledger` o dentro del
contenedor.

```bash
docker build -t frijolero .
mkdir -p ~/.local/share/frijolero && chmod 777 ~/.local/share/frijolero
docker run --rm -p 9292:9292 -v ~/.local/share/frijolero:/data \
  -e APP_PASSWORD=x -e LEDGER_DIR=/data/ledger -e OPENAI_API_KEY=... frijolero
```

## Un job que falla

La página del job muestra la salida completa. El PDF se queda en
`/data/incoming/<hex>/` en el servidor. No hay reintento. Sube el PDF otra
vez. Los directorios de las subidas fallidas se acumulan. Nada los borra.
