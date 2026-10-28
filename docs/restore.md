# Respaldar y restaurar

## El respaldo diario

Cada día a las 10:15 UTC, el servidor sube un respaldo al bucket, en
`frijolero/daily/frijolero-<fecha y hora UTC>.tar.gz`. El archivo tiene:

- La base de datos: los usuarios, los ledgers, los tokens y el consumo de
  los modelos.
- Un bundle de git de cada ledger, con todas sus ramas.
- El remoto de cada ledger, sin usuario ni contraseña.
- El log de corridas de cada ledger.

Antes de subirlo, el respaldo revisa la base de datos con
`PRAGMA integrity_check` y cada bundle con `git bundle verify`. Si una
revisión falla, no sube nada. Una regla del bucket borra cada respaldo a los
30 días (ver [Las reglas del bucket](#las-reglas-del-bucket)).

El respaldo no tiene:

- Los PDF. Ya están en el bucket.
- Las subidas que esperan en la Bandeja. Súbelas otra vez.
- Las llaves de deploy. Una llave privada no sale del volumen. Después de
  restaurar, crea una nueva (ver [Llaves de deploy](#llaves-de-deploy)).
- Los cambios sin commit de un clon. La app hace commit al final de cada
  corrida y de cada edición.
- El repo de un ledger sin commits, o de un repo propio que no conectaste.
  El log del respaldo nombra cada uno.

`kamal deploy` instala el respaldo en el servidor, con
`.kamal/hooks/post-deploy`:

- El script, en `/usr/local/bin/frijolero-backup` (es `bin/backup-host`).
- Las llaves del bucket, en `/etc/frijolero-backup.env`.
- La entrada de cron, en `/etc/cron.d/frijolero-backup`.

Cada corrida escribe una línea con el tamaño del archivo en
`/var/log/frijolero-backup.log`. Para correr un respaldo a mano y ver el log:

```bash
ssh root@<servidor> /usr/local/bin/frijolero-backup
ssh root@<servidor> tail /var/log/frijolero-backup.log
```

## Restaurar

### 1. Baja un respaldo

Bájalo desde la página del bucket en Backblaze, o con el AWS CLI y las
llaves del bucket (`b2_key_id` y `b2_application_key` en 1Password):

```bash
export AWS_ACCESS_KEY_ID=<b2_key_id> AWS_SECRET_ACCESS_KEY=<b2_application_key>
aws s3 ls s3://<bucket>/frijolero/daily/ --endpoint-url https://<endpoint>
aws s3 cp s3://<bucket>/frijolero/daily/<archivo> . --endpoint-url https://<endpoint>
```

El bucket y el endpoint están en `S3_BUCKET` y `S3_ENDPOINT` de
`config/deploy.yml`.

### 2. Restaura en un directorio vacío

```bash
bin/restore <archivo> ~/frijolero-restaurado
```

`bin/restore` escribe solo en un directorio vacío o que no existe. Copia la
base de datos y clona cada ledger desde su bundle en `ledgers/<id>/repo`. A
cada clon le pone el remoto que tenía y `core.symlinks=false`. También copia
el log de corridas. Imprime una línea por ledger, con el último commit y el
remoto.

### 3. Revisa lo restaurado

```bash
DATA_DIR=~/frijolero-restaurado bin/backup /tmp
```

Este comando hace las revisiones del respaldo diario sobre lo restaurado. Si
imprime la ruta de un archivo, la base de datos y cada repo están bien.
Después, borra ese archivo.

### 4. Córrelo en la laptop

```bash
PORT=3001 LEDGER_DIR=~/frijolero-restaurado/ledger bin/dev
```

`bin/dev` usa el padre de `LEDGER_DIR` como `DATA_DIR`. El directorio
`ledger` no tiene que existir: la base de datos ya tiene los ledgers, así que
el arranque no adopta nada. Para entrar, en otra terminal:

```bash
DATA_DIR=~/frijolero-restaurado APP_URL=http://localhost:3001 bin/signin-link <tu correo>
```

Abre el enlace y presiona "Entrar". Cuidado: un ledger con remoto hace pull y
push a ese remoto, como en el servidor. Si solo quieres revisar, no subas PDF
ni guardes ediciones.

### O ponlo en un servidor

1. En la laptop, detén la app con `kamal app stop`. En un servidor nuevo,
   primero corre `kamal setup`.
2. Copia el respaldo al servidor:

   ```bash
   scp <archivo> root@<servidor>:/root/respaldo.tar.gz
   ```

3. En el servidor, aparta lo que tiene el volumen. `bin/restore` escribe solo
   en un volumen vacío.

   ```bash
   mkdir /root/frijolero-antes
   mv /var/lib/docker/volumes/frijolero_data/_data/* /root/frijolero-antes/
   ```

4. En el servidor, restaura con la imagen de la app, como su usuario:

   ```bash
   IMAGE=$(docker ps -a --filter label=service=frijolero --format '{{.Image}}' | head -1)
   docker run --rm -v frijolero_data:/data -v /root/respaldo.tar.gz:/tmp/respaldo.tar.gz:ro \
     "$IMAGE" bin/restore /tmp/respaldo.tar.gz /data
   ```

5. En la laptop, arranca la app con `kamal app start`.
6. Crea las llaves de deploy (abajo).

## Llaves de deploy

Un ledger con remoto por SSH necesita su llave de deploy para pull y push.
El respaldo no la trae, así que cada corrida de ese ledger falla hasta que
tenga una nueva.

Para cada ledger con remoto por SSH (`bin/restore` imprime su `git@…`):

1. Crea la llave y muestra su parte pública:

   ```bash
   kamal app exec --reuse 'ssh-keygen -q -t ed25519 -N "" -C frijolero -f /data/ledgers/<id>/deploy_key'
   kamal app exec --reuse 'cat /data/ledgers/<id>/deploy_key.pub'
   ```

   En la laptop, corre `ssh-keygen` con la ruta del directorio restaurado,
   sin `kamal app exec`.

2. En GitHub, abre el repo del ledger → Settings → Deploy keys. Borra la
   llave vieja. Agrega la nueva y marca "Allow write access".
3. En la app, presiona "Actualizar" en un reporte para probar el pull.

## Las reglas del bucket

Un bucket de B2 guarda cada versión de un archivo. Cuando la app borra un PDF,
B2 solo lo oculta, y lo sigue guardando y cobrando. Dos reglas del bucket
hacen el borrado de verdad. Ponlas a mano en la página del bucket en
Backblaze → Lifecycle Settings → Use custom lifecycle rules. El bucket es de
varias apps, así que cada regla nombra un prefijo de Frijolero:

| Prefijo | Ocultar a los | Borrar lo oculto a los |
|---|---|---|
| `frijolero/ledgers/` | (vacío) | 30 días |
| `frijolero/daily/` | 30 días | 1 día |

La primera borra los PDF de un ledger borrado, y las versiones viejas que
deja "Sobrescribir". La segunda borra cada respaldo a los 30 días.

## Recuperar un ledger borrado

Durante 30 días después de borrar un ledger, un respaldo de antes del borrado
todavía tiene su repo, y el bucket todavía tiene sus PDF ocultos. Después, no
queda nada.

1. Baja un respaldo de antes del borrado (paso 1 de [Restaurar](#restaurar)).
2. Saca el bundle del ledger y clónalo:

   ```bash
   tar -xzf <archivo> ./ledgers/<id>.bundle
   git clone ledgers/<id>.bundle <id>
   ```

3. Lista las versiones de sus PDF y baja la que quieras, con las llaves del
   paso 1:

   ```bash
   aws s3api list-object-versions --bucket <bucket> --prefix frijolero/ledgers/<id>/ \
     --endpoint-url https://<endpoint>
   aws s3api get-object --bucket <bucket> --key '<Key>' --version-id <VersionId> <archivo>.pdf \
     --endpoint-url https://<endpoint>
   ```

El repo y los PDF quedan en la laptop. Para usarlos en la app, crea un ledger
nuevo con el repo como remoto, y sube los PDF otra vez.
