# Instalar, correr y desplegar

## Requisitos

- Ruby 4.0.6. La versión está en `.ruby-version`.
- git. La app lo usa como subproceso para el ledger.
- rustledger, para los reportes. En la laptop: `brew install rustledger`.
  La app busca `rledger` en el PATH, o en la variable `RLEDGER`.
- Un ledger: un repo de git con el layout de [ledger.md](ledger.md). Si no
  tienes uno, `bin/new-ledger` lo crea.

## Correr en la laptop

1. Instala las gemas con `bundle install`.
2. Copia `.env.example` a `.env` y pon la ruta de tu ledger en `LEDGER_REPO`.
   Las demás líneas son opcionales.
3. Si quieres ver la página Cuentas o descargar un PDF, llena las variables
   de B2 en `.env`.
4. Si quieres subir un estado de cuenta, pon `OPENAI_API_KEY` en `.env`.
   Una subida gasta dinero y hace commit al ledger.
5. Corre `bin/dev`.
6. Abre http://localhost:3000. La página te pide la contraseña en un formulario. La contraseña es `x`.

`bin/dev` lee `.env` y enlaza el ledger en `tmp/dev/ledger`. Así el log de jobs
y los PDF subidos quedan en `tmp/dev`, y no junto al repo del ledger. La ruta
`/up`, `/login` y los archivos estáticos (`/style.css`, `/reports.js`) responden
sin necesidad de la cookie de sesión.

## Variables de entorno

| Variable | Uso |
|---|---|
| `LEDGER_DIR` | El clon del ledger. Obligatoria. El directorio padre guarda el log de jobs y las subidas. |
| `LEDGER_MAIN_FILE` | El archivo principal del ledger, relativo a `LEDGER_DIR`. Por defecto, `transactions.beancount`. |
| `APP_PASSWORD` | La única credencial. Se verifica en el formulario de login y firma la cookie de sesión que dura 30 días. Cambiar la contraseña cierra todas las sesiones en todos los dispositivos. Obligatoria. |
| `OPENAI_API_KEY` | Para clasificar y extraer. |
| `OPENAI_POLL_TIMEOUT` | Segundos de espera para una extracción. Por defecto, 900. |
| `B2_ENDPOINT`, `B2_BUCKET`, `B2_KEY_ID`, `B2_KEY` | Backblaze B2, compatible con S3. Los PDF viven ahí. |
| `GIT_TOKEN` | Un token fine-grained de GitHub con permiso de lectura y escritura de contenido en el repo del ledger. Viaja como header HTTP en cada llamada a git. Nunca se escribe en disco. |
| `PUMA_THREADS` | El tamaño del pool de threads. En producción, 3. |
| `RLEDGER` | El binario de rustledger. Por defecto, `rledger` en el PATH. |

Si una llave de B2 trae un espacio, la app lo quita. Un espacio en 1Password
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
reglas, en las cuentas, en los prompts o en el modelo de OpenAI es un commit
en el repo del ledger. La app lee esos archivos en cada request y en cada job.
El servidor recibe el cambio en el siguiente job, o de inmediato con este
comando:

```bash
kamal app exec --reuse 'bundle exec ruby -Ilib -e "require %q(frijolero); Frijolero::LedgerRepo.new(dir: ENV.fetch(%q(LEDGER_DIR))).pull"'
```

El botón "Actualizar" de los reportes hace lo mismo.

### La imagen en la laptop

```bash
docker build -t frijolero .
docker run --rm -p 9292:9292 -e APP_PASSWORD=x -e LEDGER_DIR=/data/ledger frijolero
```

## Un job que falla

La página del job muestra la salida completa. El PDF se queda en
`/data/incoming/<hex>/` en el servidor. No hay reintento. Sube el PDF otra
vez. Los directorios de las subidas fallidas se acumulan. Nada los borra.
