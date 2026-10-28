# CLAUDE.md

Guidance for Claude Code in this repository. The code shows what each part does. This file gives what the code does not show: the layout outside the repo, the decisions and their reasons, and the traps.

## What this is

Frijolero is a Ruby 4.0 web app. It turns statement PDFs from banks, cards and brokers into Beancount. It runs Sinatra on Puma in one process. Each ledger is a git repo. A SQLite file holds the users, the ledgers and the model usage.

The flow:

1. The person uploads a PDF.
2. The app finds the account and the period, and the person confirms them.
3. A background job extracts the transactions with a model (OpenAI or Anthropic), applies the rules of the account and writes a `.beancount` file.
4. The job adds the file to the ledger, then commits and pushes.

The ledger is a separate git repo. The PDFs live in an S3-compatible bucket, or on disk when no bucket is set. The user docs are in Spanish: `README.md`, `docs/setup.md`, `docs/ledger.md` and `docs/rules.md`.

## Commits

- Escribe los mensajes de commit en español, simples y concisos.
- Work on local `main`. The user pushes when they decide to. Do not open a pull request for each change.
- Before you write code that runs git, read "Git subprocesses".

## Commands

```bash
bundle exec rake test && bundle exec rubocop    # both must pass before a commit (bin/test runs both)

bin/dev                                          # the app on http://localhost:3000; sign in as admin@localhost, the link is in the terminal; reads .env (see .env.example)
bin/demo-ledger tmp/demo --persona contractor --income 65000   # a fake ledger with three banks, 24 months, rules, PDFs and a job log
LEDGER_DIR=tmp/demo/ledger bin/dev               # the app on that fake ledger

kamal deploy                                     # deploy a code change; needs 1Password unlocked (see Operations)
kamal app exec --reuse '<cmd>'                   # run a command in the production container
```

Without `LEDGER_REPO` in `.env`, `bin/dev` keeps its data in `~/.local/share/frijolero`, and the first run creates a ledger there. With it, the data is in `tmp/dev`. The boot stops, and lists the `.beancount` files that it sees, when a ledger that waits for adoption (see "Outside the ledger") has no main file.

## Where things live

This repo:

```
config.ru     runs the migration, then starts App behind Login, Admin, Ledgers and LedgerScope
app/          the Sinatra process: App, its route files, Dashboard, Jobs, views/
public/       style.css, reports.js, editor.js, charts.js, and the vendored d3 files
lib/          the pipeline, with no Sinatra; lib/frijolero.rb requires the rest
prompts/      one directory per prompt type: spec.json, instructions.txt, schema.json
db/           the SQLite schema, one <n>_*.sql per version
templates/    ledger/, the seed that bin/new-ledger copies
bin/          dev, test, test_fast, new-ledger, demo-ledger, signin-link, backup, restore, backup-host
config/       deploy.yml, puma.rb
test/         mirrors app/ and lib/; fixtures/ holds sample statements and prompts
```

### The ledger repo

The ledger is a private repo on GitHub. `CLAUDE.local.md` (git-ignored) has its URL and the other private values. `bin/new-ledger` creates a ledger from `templates/`. On an existing ledger, it adds only the missing `config/` files.

The ledger has three copies:

| Copy | Where | Who writes |
|---|---|---|
| Laptop | A clone with an SSH remote | The user, by hand: pull with rebase, commit, push. |
| Droplet | `/data/ledgers/<id>/repo` in the container, SSH remote with the ledger's deploy key | The app: jobs, editors and rule runs. |
| GitHub | origin | Nobody directly. |

The app keeps its copy in sync like this:

- Each job pulls with rebase before it starts, and commits and pushes at the end.
- `LedgerRepo#commit_and_push` pulls with rebase again between the commit and the push, because the laptop can push in the meantime.
- A rebase conflict aborts the rebase and raises. The commit stays local.
- A clone with no remote (a setup on the laptop only) skips the pull and the push.
- The "Actualizar" button on the report pages runs a pull.

Layout of a ledger clone (`Config.ledger_dir`, the repo of the current ledger). `Config` derives each path from it:

```
main.beancount            the main_file of the ledger's row: options, opens, and one `include` per statement
account_opens.beancount   optional; when it exists, new `open` lines go here and not in the main file
config/accounts.yaml      account key → beancount_account, openai_prompt_type, converter_type, description, cutoff_day, closed
config/rules/<Key>.yaml   the rules of one account; the name keeps spaces ("BBVA TDC.yaml")
accounts/<Key>/<Key> YYMM.beancount   and the .json next to it
```

A ledger made before the prompts moved into the app still has `config/prompts/`. Nothing reads it.

`YYMM` is the month that holds most of the days of the statement. The user's own ledger is older than the template. Its main file is `moneys.beancount` (the migration took it from `LEDGER_MAIN_FILE` in `deploy.yml`), and it includes other files. Beancount does not care which file holds an entry, so the app appends to the main file.

A change to the rules or the accounts is a commit in the ledger, not a deploy. The app reads those files on each request and each job. The droplet gets the change at its next pull. A change to a prompt or a model name is a deploy: the prompts are in `prompts/` of this repo, the same for every ledger, because the app pays for the model and so it chooses the models. To pull every ledger from the shell:

```bash
kamal app exec --reuse 'bundle exec ruby -Ilib -e "require %q(frijolero); Frijolero::Ledger.all.each { |l| Frijolero::LedgerRepo.for(l).pull }"'
```

### Outside the ledger

On the volume (`DATA_DIR`, which is `/data` in production):

- `frijolero.sqlite3`: the users, the ledgers, the sign-in and API tokens, the passkeys, and one usage row per model call. The schema is `db/*.sql`.
- `ledgers/<id>/repo/`: the clone of each ledger.
- `ledgers/<id>/jobs.jsonl`: the append-only job log of that ledger.
- `ledgers/<id>/incoming/<token>/`: one directory for each upload, with `<original name>.pdf` and, after the classifier, `classification.json`. A successful job removes it.
- `ledgers/<id>/pdfs/`: the PDFs, when no bucket is set.

Before the database, the volume held one ledger: `ledger/`, with `jobs.jsonl`, `incoming/` and `pdfs/` next to it. At boot, `Migration` makes the admin from `ADMIN_EMAIL` when there is no admin. When there is no ledger, it also adopts that old ledger (`LEDGER_DIR`, by default `DATA_DIR/ledger`): one row, and each file moved by a rename. A second boot does nothing. The rehearsal on a copy of production, on 2026-10-23, moved the ledger, `jobs.jsonl` and `incoming/`, and every page served as before.

In the bucket, which other apps share: `<pdf_prefix>/accounts/<Key>/<Key> YYMM.pdf`. The adopted ledger has the prefix `frijolero`, the one that every key had before. A new ledger gets `frijolero/ledgers/<id>`. `Config.pdf_key` is the only formula for that key.

## Environment variables

| Variable | Purpose |
|---|---|
| `DATA_DIR` | The volume: the database and `ledgers/`. |
| `ADMIN_EMAIL` | The first admin, made at boot when there is none. In 1Password, the field is `admin_email`. `bin/dev` uses `admin@localhost`. |
| `LEDGER_DIR`, `LEDGER_MAIN_FILE` | Read only when the database has no ledger: `Migration` adopts that clone and records its main file (default `main.beancount`). |
| `LLM_PROVIDER`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` | `LLM_PROVIDER` is `openai` (default) or `anthropic`. Without the key of that provider, `LLM.client` is nil and the app cannot classify or extract. The model names are in `prompts/*/spec.json`, so a change of provider changes them too. |
| `LLM_TIMEOUT` | Default 900 s. It is the poll deadline for OpenAI and the read timeout for Anthropic. |
| `SESSION_SECRET` | Signs the session cookie (30 days). rack-session needs 64 bytes or more. A new secret logs out every device. In 1Password, the field is `session_secret`. `bin/dev` sets a fixed one. |
| `APP_URL` | The base of the sign-in links (`https://frijolero.pati.to`), and the origin and site of the passkeys. The links never come from the request's Host header, because a forged header could point a link at another site. `bin/dev` uses `http://localhost:$PORT`. |
| `POSTMARK_API_TOKEN`, `MAIL_FROM` | The sign-in emails go through the HTTP API of Postmark, because DigitalOcean blocks SMTP. Without the token, `Postmark.deliver` writes the email to the log. In 1Password, the field is `postmark_api_token`. |
| `S3_ENDPOINT`, `S3_BUCKET`, `S3_KEY_ID`, `S3_KEY` | Any S3-compatible store (B2 in production). The endpoint is a bare host. With none of the four, the PDFs go to disk (`LocalPdfs`). With only some, `S3.from_env` raises and names the missing ones. It also removes whitespace from the keys: a stray space from 1Password once caused `Signature validation failed`. |
| `S3_REGION`, `S3_PATH_STYLE` | Optional. The default region is the second segment of the endpoint, which is correct for B2 and AWS. R2 needs `auto`, Hetzner its location, and DigitalOcean and MinIO `us-east-1`. `S3_PATH_STYLE=1` puts the bucket in the path, for MinIO on localhost or a bucket name with a dot. |
| `PUMA_THREADS` | The size of the thread pool (3 in production). |
| `RLEDGER` | The rustledger binary for the reports and the error check (default `rledger` on the PATH). The image has 0.24.0. On the laptop: `brew install rustledger`. |
| `TZ` | `America/Mexico_City`, set in the Dockerfile. `Date.today` and the job times follow it. |

## Architecture

### Request side (`app/`)

- `app/app.rb` holds the settings, the collaborators, the dashboard and the job pages. Each other file in `app/` reopens `App` for one area. `app/` is the only place that requires Sinatra.
- `App` has seven collaborators: `jobs`, `inbox`, `inbox_worker`, `client`, `s3`, `repo` and `reports`. `jobs` and `inbox_worker` exist once per ledger, because each holds a thread. `inbox`, `repo` and `s3` are built for the current ledger on each call. Tests replace a collaborator through its `attr_writer`, and that one then serves every ledger.
- The current ledger (`lib/ledger.rb`) is per thread: `Thread.current`, not `Fiber[]`, which a new thread inherits. Without one, a ledger path raises `NoLedger`, so code that forgot it fails instead of reading another ledger. `LedgerScope` sets it for each request, and `Ledger.with` clears it at the end. The job body and the Bandeja worker set it with `Ledger.with`, from the ledger of the request that queued them.
- Each ledger page is under `/l/<id>/`. `LedgerScope` (`app/ledger_scope.rb`), between `Login` and `App`, is the trust boundary:
  - The ledger must exist and belong to the signed-in user. Else the answer is 404, the same for an unknown id and for the ledger of another user, admin included. `test/app/isolation_test.rb` tries each route of `App` against another user's ledger.
  - It moves `/l/<id>` into `SCRIPT_NAME`, so the routes of `App` keep their plain paths.
  - A ledger with no `repo/` yet (an own repo that is not connected) goes to its connect page.
  - A GET to a path from before `/l/<id>/` (a bookmark) goes to the same path in the user's first ledger. Any other method there is a 404, so a stale form cannot post to the wrong ledger.
  - `/api/` keeps its path and runs in the ledger of its token.
  - Its 404 (`LedgerScope.not_found`) is also the 404 of `Admin` and `Ledgers`.
  - Puma gives `PATH_INFO` as a binary string, and SQLite compares a binary string as a BLOB, which matches nothing. So a value from the path goes to SQLite as UTF-8.
- Paths in `App` stay plain (`/accounts/AMEX`). A link gets the prefix where it is written into HTML: `ledger_path('/accounts')` in a view, or in a helper that writes an `<a>`. `set :prefixed_redirects, true` adds it to every redirect. The JavaScript reads it from `<meta name="ledger-root">` in `_head.erb`. A value that comes back to the server and is compared with plain paths stays plain: the hidden `back` field and the `action` local of the editors. The static files and `/logout` stay outside the prefix.
- The pages outside a ledger are Sinatra middlewares between `Login` and `LedgerScope`. They inherit `Page` (`app/page.rb`), share the header `_bar.erb`, and pass down every path that they do not route. They have no current ledger: a page names its ledger by id and checks the owner.
  - `Ledgers` (`app/ledgers.rb`) owns `/` and `/ledgers/…`. `/` opens the user's only ledger, lists them when there are several, and offers a new one when there is none. A new ledger is the template (`NewLedger`), or the person's own repo: the connect page makes a deploy key, the person adds it to GitHub or GitLab with write access, and the app clones over SSH. After the clone of an empty repo, the first push is `git push -u origin HEAD`. A person has at most 5 ledgers (`Ledgers::MAX_LEDGERS`), because each ledger holds two threads from boot.
  - `Admin` (`app/admin.rb`) owns `/admin/…`, for the admin only. There is no sign-up: the admin invites each person, with a link that lives 7 days (`Signin.invite`). Block and "Cerrar sesiones" add 1 to `session_version`. The cap is in USD, and empty means 3 USD. The admin cannot act on their own row, so the only admin cannot lock themselves out.
  - `PasskeysPage` (`app/passkeys.rb`) owns `/passkeys…`: the passkeys of the signed-in user (see Sign-in). The delete has the user in its `WHERE`, so a person cannot delete the passkey of another.
- Inside a ledger, `/ledger` (`app/ledger_settings.rb`) renames it, changes its main file, adds a remote, and exports HEAD as `.tar.gz`. It never makes a key for a ledger with an origin: its remote already trusts the key that the ledger has. `/tokens` (`app/api_tokens.rb`) makes and revokes the API tokens of the ledger, and shows a new token once.
- `Login` (`app/login.rb`) is the outer middleware, in front of the rest. So its pages have no current ledger, and they must not read one. It owns `/login`, `/login/<token>`, `/login/challenge`, `/login/passkey` and `/logout`. It sends each request without a valid session to `/login`.
  - A session is valid while its user is active and its `session_version` matches. Login puts the user in `env['frijolero.user']`.
  - A request to `/api/` needs `Authorization: Bearer <token>` instead, with a token from `api_tokens` (`lib/api_tokens.rb`) whose ledger has an active owner, and gets a JSON 401 without it. The database keeps only the SHA-256 of a token, and the token names its ledger. The Shortcut's token was `API_TOKEN` until Stage 4; the migration of Stage 1 put it in the table.
  - `App` and its tests never see auth.
- Sign-in is by email link (`lib/signin.rb`) or by passkey. There are no passwords.
  - A link works once, for 15 minutes. The database keeps only the SHA-256 of its token.
  - `GET /login/<token>` only shows a button, because mail scanners open the links in an email. The POST signs in.
  - `POST /login` answers with the same page for every email. A user gets at most 1 link a minute and 5 an hour.
  - The link page sends `Referrer-Policy: no-referrer`, because its URL holds the token and it loads Google Fonts.
  - `bin/signin-link <email>` prints a link. It is the way in when the email fails: `kamal app exec --reuse 'bin/signin-link <email>'`. `/up` and the static files are outside it. `Login` serves the static files itself, so a static setting (such as `static_cache_control`) goes on `Login`; on `App` it does nothing.
- A passkey (`lib/passkeys.rb`, `public/passkeys.js`) is the other way in. An invited person enters the first time with the email link. Then they make a passkey at `/passkeys` (Opciones → "Llaves de acceso").
  - The login page offers the passkeys in the autofill of the email field (`autocomplete="email webauthn"`, conditional mediation). `passkeys.js` fetches the options from `POST /login/challenge`. So the challenge is never in the page, and `POST /login` still answers the same page for every email.
  - The challenge waits in the session for 5 minutes. The first answer removes it, so an answer works once.
  - The site is the host of `APP_URL`, and the origin is `APP_URL`. A new domain makes every passkey useless. The email link still works.
  - The app asks for no attestation, so it parses no CBOR. The browser gives the public key as DER (`getPublicKey()`), and OpenSSL checks the signature. The algorithms are ES256 and RS256. The `webauthn` gem would add 7 gems for the same checks.
  - A sign-in needs the UV flag (Face ID, Touch ID or a PIN), because the passkey replaces the email. It ignores the sign count, because a synced passkey always sends 0.
  - The passkey routes come before `/login/:token` in `app/login.rb`. Else Sinatra takes `challenge` and `passkey` as tokens.
  - Block stops the passkeys of a user, because the user is not active. "Cerrar sesiones" keeps them.
  - A passkey that the person deletes at `/passkeys` stays on the device, and the autofill still offers it. The sign-in then fails with a message.
  - `test/fake_passkey.rb` is an authenticator for the tests. There is no JavaScript test. In a browser, the WebAuthn panel of Chrome DevTools gives a virtual authenticator.
- The views are standalone ERB pages in Spanish, with no layout. Each page calls the `head` and `topbar` helpers.
- All pages of one account are under `/accounts/<Key>`. A statement has three URLs: `/accounts/<Key>/<YYMM>` (the movements), `…/beancount` (the text) and `…/beancount/edit` (the text in the editor). The route constraints in `app/statements.rb` keep `config` and `rules` out of the period segment.
- With no account in `accounts.yaml`, a filter sends every `/upload` route to `/accounts/new`, and `/api/upload` answers 422. So no model call can happen before the first account exists.

### Design rules (`public/style.css`)

The CSS follows the 1975 NASA Graphics Standards Manual:

- White ground, black type, one heavy rule under the header, and thin rules elsewhere.
- NASA blue for links and the primary button.
- NASA red only on the wordmark and on things that need action. Red marks (■, a band, the error disc) carry it, never words, because red text has a contrast of 3.6:1 on white.
- Public Sans for text. IBM Plex Mono for Beancount, dates and amounts.
- One set of tokens with `light-dark()` for both color schemes. The tints are set by eye for each scheme, because a percentage mix disappears on black.

A status is a glyph and a word (`.status.<name>`): ● received or ok, ○ pending or queued, ◐ running, ▲ missing, ■ failed. Color is never the only signal. An empty page says what to do next.

Under 40rem, each table becomes a list of blocks. The first cell becomes the heading, and each `td[data-label]` becomes a label and a value. An empty cell disappears. So write a cell that can be empty with no whitespace inside it.

### Dashboard (`app/dashboard.rb`)

`Dashboard` computes a status for each open account on each request. Its two columns are the newest period that some account has closed and the period before it. An account closes a statement on its `cutoff_day` (31, or none, means the last day of the month). That statement belongs to the month 15 days before the closing date, the same rule as the classifier. Before the cutoff, the column shows pending.

Received links to the statement, missing to `/upload`, and failed to the newest failed job with that label. The first confirmed upload with a printed period end fills in `cutoff_day`. The job never overwrites it, so a hand edit wins.

### Cuentas (`app/accounts.rb`)

- `/accounts/<Key>` lists the PDFs of the account from the bucket. Each period between the oldest PDF and the newest closed period gets a row, so a gap shows as missing. A bucket error shows on the page, with status 502.
- `/accounts/<Key>/config` edits only the block of the account in `accounts.yaml`. `AccountBlock` cuts the block by line range, so the comments in the rest of the file stay. The key cannot change.
- At the bottom of `/accounts`, "Otros archivos beancount" links the main file and each file that it includes, at any depth, outside `accounts/` to its editor at `/files/<path>`. The list comes from `LedgerFiles.all`. A file that nothing includes does not show, because rledger never reads it.
- An account key matches `Config::ACCOUNT_KEY`: letters, numbers, spaces, `.`, `_` and `-`, and not `.` or `..`. The key becomes a directory and the start of file names, so `Config.accounts` skips any other key, and the new-account form and the `accounts.yaml` editor refuse it.
- `/accounts/new` adds one account for the Default pipeline. `NewAccount` appends the block and an `open` line, unless a line already opens that account. The other pipelines need extra accounts, so they use `/accounts/yaml`, the editor for the whole file.

### Upload flow (`app/uploads.rb`)

1. The web form (`POST /upload`, field `pdf[]`) and the iOS Shortcut (`POST /api/upload`, field `pdf`) save each PDF in `incoming/<token>/` and queue it for `Inbox::Worker`. They answer at once: the form redirects to `/inbox`, and the API answers 202 with the URL of the Bandeja of its ledger. If one file is not a PDF, nothing is saved.
2. A file name like `<Key> YYMM.pdf` needs no model. Any other name costs one model call with the `classify` prompt. Without a model key, the answer is an error that names the key variable, and the Bandeja offers only "Solo guardar PDF".
3. The classifier takes the period from the midpoint of the printed start and end, so AMEX Aug 4 to Sep 3 is `2608`. A doubtful answer becomes `unknown`.
4. The Bandeja shows the answer, and the person confirms or changes it. If that statement exists, the row shows the Sobrescribir box. Without overwrite, the job refuses an existing statement.
5. "Procesar" (`POST /inbox/process`) queues a job. "Solo guardar PDF" (`POST /inbox/backup`) puts the PDF in the bucket during the request and removes the upload. It skips the model, the ledger and the job log.

The buttons that wait on the server have `data-busy`. `reports.js` writes that word on the button and makes the form `inert`, so a second click sends nothing. The `pageshow` event restores them when the back button shows the page from the cache.

### Bandeja (`app/inbox.rb`, `/inbox`)

The Bandeja holds the uploads that wait for a person. The API answers in JSON, errors included, because a Shortcut reads a body more easily than a status. The person always confirms: nothing is processed without a click.

- `Inbox` only reads and writes the disk. A page that counts the Bandeja starts no thread.
- `Inbox::Worker` is a second queue and thread for each ledger, apart from the job worker, so an extraction never holds up a classification. At boot, it queues each upload that has no `classification.json`. A model error becomes the answer (`{"error": …}`), and the worker goes on.
- `Inbox#rows` leaves out each upload that a queued or running job holds. Each row has one status: classifying, error, failed (its newest job failed), unknown, exists, repeated (two uploads with the same account and period) or ready. Only ready rows go into "Procesar los listos".
- The page is one form. Each row sends `account[token]`, `period[token]` and `overwrite[token]`. A button sends the tokens to process in `tokens`, so one row and "Procesar los listos" use the same route. The first submit button of the form is hidden and disabled, so Enter in a period field submits nothing.
- Procesar writes the choice into `classification.json` before it queues the job. So a row whose job fails comes back as the person left it.
- The page refreshes every 3 s while a row is classifying. A refresh loses an edit that is not submitted.
- The dashboard shows "▲ N por confirmar" when the Bandeja is not empty. There is no tab, because four tabs do not fit on a phone.
- At the owner's monthly cap (`Usage.capped?`), the classifier makes no model call and answers `{"error": "Límite del mes"}`, and "Procesar" and "Reintentar" answer 422. A `<Key> YYMM.pdf` name, "Solo guardar PDF" and a job already in the queue still work. The dashboard shows "Uso del mes: 1.20 de 3.00 USD".

### Jobs (`app/jobs.rb`)

Each ledger has its own `Jobs`: one `Queue`, one worker thread and its `jobs.jsonl`. So the jobs of one ledger run in order, and one ledger never waits for another. `Log.sink` is per thread, so two jobs at once keep their output apart. At boot, it marks the jobs left `running` or `queued` as failed. The job body is `repo.pull` under the ledger's lock, then `Statement#process`, whose block runs the cutoff day and `repo.commit_and_push("<Key> YYMM")` inside the lock of its writes, then the removal of the upload directory. The body writes its output through `Log.sink`. The UI calls a job a "corrida".

A failed job shows "Reintentar" only when a model key is set and `retryable_upload` is true:

- The job has an upload token. Jobs logged before the token existed have none.
- The account still exists.
- The `.beancount` of that statement does not exist. A later success for the same label ends the retry.
- The upload directory still holds the PDF. `Statement` deletes it after the extraction, so a retry is possible only after a failure at the extraction, such as a 429.

The retry runs with overwrite off and does not record the cutoff day. While the PDF is there, the upload also shows in the Bandeja as failed, and Procesar there is a retry too. The job log stores times in UTC. The pages show them in local time, with the status words in Spanish.

### Statement (`lib/statement.rb`)

`Statement` processes one PDF for an account and a period. The steps, in order:

1. Find the account in `accounts.yaml`. A pull can remove it after the confirm.
2. Refuse if the outputs exist and `overwrite` is false.
3. Put the PDF in the bucket.
4. Extract. The PDF goes inline, in base64, in one request.
5. Run `pipeline.validate!`.
6. Delete the local PDF.
7. Save the JSON, apply the rules (when the pipeline has rules and the account has a rules file), convert, and add the `include` line.

The order protects the PDF. The bucket has it before the paid step, and the local copy survives each failure before step 6. `LLM.report` gives each `LLM::Error` class a policy. A recoverable error (rate limit, network, API) gives the result `ERROR`, so the job fails with that status. A bad key or no credit raises again.

Steps 3 to 6 take minutes and hold no lock. Step 7 and the caller's block (the cutoff day and the commit) run in one `Ledger.lock`. An error there raises, and the job fails with its message.

### Pipelines (`lib/pipeline.rb`)

`Pipeline.for(account_config)` selects a strategy from `converter_type`: `Default`, `Multi`, `CetesDirecto`, `Fintual` or `Alpaca` (`plata` is the old name of `alpaca`). A strategy gives the summary line, owns `validate!`, can change the extraction request, and calls its converter. A new statement type is one strategy and one converter.

Only `Default` and `Multi` have rules. For the other pipelines there are no rule links, no rules editor and no "Aplicar reglas", and `/accounts/<Key>/rules` is a 404.

`Multi` is a `Default` for one PDF that covers several accounts at one bank, each in a section "Movimientos de <name>". The `accounts` map in `accounts.yaml` connects each printed name to a Beancount account. The `account` enum of the schema holds only the printed names, so the model never sees a Beancount name. A transfer between two of those accounts appears once in each section. When a rule points a row at another account of the same statement, `Multi#convert` drops the mirror row (same date, opposite amount).

### Statement page (`app/statements.rb`)

The page reads the `.beancount` file, not the JSON. The JSON is fixed at job time, but the rules, the edit dialog and hand edits change the file. `StatementRows` takes the amount from the source posting (on `beancount_account`, or on an account of a Multi). The other postings are the classification, and `Expenses:FIXME` means unclassified.

- The movements and the Beancount text are two views, each at its own URL. The server renders only the current view.
- The date of a movement opens the edit dialog on that transaction (see Editors). So a person can classify one movement without a rule.
- "▲ N sin clasificar" is a filter. It links to `#sin-clasificar`, which is the `<body>`, so the page does not scroll. While the body is the `:target`, CSS hides every row that is not `li.fixme`, shows the status as a black block and shows "Ver todos". There is no script. A save in the edit dialog reloads with the hash, so the filter stays and the saved row leaves it.
- "Aplicar reglas" shows only while something is unclassified and the rules file exists, because the rules touch only FIXME postings.
- `beancount_html` colors the text with one regex over the escaped text. A line that matches nothing stays plain, so a hand edit never breaks the page. There is no highlighting library.

For the other pipelines, the page shows only the extraction summary and the Beancount text.

### Rules (`lib/detailer/`, `lib/beancount_detailer.rb`, `app/editors.rb`)

`Detailer::Rules` is the pure matcher (see Data formats). Before it matches, it collapses the whitespace of the description, as the converter does when it writes the narration. So a rule matches the same text in the JSON, where the model can keep line breaks, and in the `.beancount` file.

`Detailer` applies the rules to the JSON at job time. `BeancountDetailer` applies them again to a `.beancount` file. It changes only transactions that still post to `Expenses:FIXME`, and it ignores transactions with the `!` flag. So it is idempotent, and hand edits are safe. `POST /accounts/<Key>/<YYMM>/detail` runs it and commits only when something changed.

The rules editor:

- Saves with LF line endings. A browser sends a textarea with CRLF, and an early version saved the file that way.
- Validates with `YAML.safe_load` and a probe call to `matches_for`.
- Adds the "Hacer regla" entry as text (`with_rule`), not with `YAML.dump`, so the comments, the quotes and the order stay.
- Leaves the new fields empty. `Rules.merge` skips an empty field, so a blank payee keeps the payee of the transaction.
- Returns to the statement after a save through `back`. `back_path` accepts only `/accounts/<Key>/<YYMM>`.

### Editors (`app/edits.rb`, `lib/ledger_edit.rb`, `app/views/_code.erb`, `public/editor.js`)

One editor shows and edits Beancount text. It works in three places: the Beancount view of a statement, any ledger file at `/files/<path>`, and the edit dialog of one transaction. The dialog opens from a date in the journal or on a statement. The YAML editors (rules and `accounts.yaml`) use the same surface, with their own colors.

A `pre` shows the colored, numbered lines. In edit mode, a transparent textarea with the same font, padding and wrapping lies on top. The `pre` sets the height, so there is no scroll to sync. Three rules keep the caret on the text:

- Nothing inside `.surface` can change the height of a line. Use backgrounds and shadows, never borders or inline text. That is why an error message is a `title` and a list item.
- `BEANCOUNT_TOKEN` in `app/statements.rb` and its copy in `editor.js` must stay identical.
- Bold mono text is safe only in a weight that the page loads. `_head.erb` loads IBM Plex Mono at 400, 500 and 600, which all have the same width. A weight that is not loaded becomes a synthetic bold, which is wider and moves the caret. Add a new weight to the font URL first.

The save (`POST /edit`):

- `LedgerEdit` checks `file` and `line`. It compares real paths, so a symlink cannot lead out. A path outside the ledger, a file that does not exist, or a file that is not `.beancount`, is a 404. This is the trust boundary.
- `line` can point at any line of a transaction, and `LedgerEdit` walks back to its header. No `line` means the whole file.
- If the block no longer matches the `original` that the form sent, the answer is 409. A job or a pull changed the file.
- The save runs `Reports.check` before and after the write. It puts the file back and answers 422 only when the edit adds errors, counted by code and file. So a person can repair a ledger that has errors one edit at a time.
- A clean check commits and pushes. A git failure is 502, and the file stays saved and committed locally.
- The save holds the ledger's lock from its first check to the push.

rledger prints real paths. `Reports.ledger_file` makes them relative to the real path of `LEDGER_DIR`, because `bin/dev` gets to the ledger through a symlink.

The account autocomplete lists `LedgerAccounts.active`: the `open` lines minus the `close` lines, in every file that rledger reads (`LedgerFiles.all`). A name that only a rule uses, or a closed account, fails the check. The list opens only where an account goes (`BEANCOUNT_SPOT`, `RULES_SPOT` and `ACCOUNTS_SPOT` in `editor.js`). It is a script because a textarea cannot use a `<datalist>`.

### Converters (`lib/converters/`)

Every amount goes through `BigDecimal`, because a float residue such as `-5.55e-17` breaks Beancount. `Amounts` writes thousands with commas (`-15,596.89 MXN`). Beancount accepts them, and `Beancount::Transaction` removes them when it reads an amount back. `BeancountMerger` adds an `include` line, relative to the directory of the main file.

### CetesDirecto

The CetesDirecto pipeline keeps lots. Each security has a FIFO sub-account and a commodity of the same name (`<account>:CETES-280412`). The cash is in `<account>:Cash`, and the BBVA rule for NAFIN transfers points there. Each month ends with a price for each holding and a balance on the cash and on each holding, so a wrong row fails the check instead of hiding in a plug.

These behaviors are on purpose:

- A coupon row (PAGINTCU) prints `PESOS PESOS`. The ISR row with the same folio names the bond, so the converter joins the rows of one folio into one transaction.
- A maturity (AMORTIZACION) sells the lots at the amount paid, and the difference with cost goes to `interest_account`. The statement counts it the same way, so the interest of a year equals "Intereses acumulados del ejercicio".
- A BONDDIA sale (VTASI) books its difference with cost to `gains_account`. The income statement shows only realized income. A change in market value shows on the balance sheet, as "Ganancias no realizadas".
- "Total de efectivo" and "Saldo final" can differ by one centavo, and the next statement starts from "Total de efectivo". A "Redondeo" entry closes the gap.
- `validate!` repeats the reconciliation of the statement: each row has a known type, the movements take each security from its opening titles to its closing titles, and they take the cash from "Saldo inicial" to "Saldo final". A failure stops the job while the PDF is still there for a retry.
- The converter writes the Cetes side of a transfer, and the BBVA statement has the other side. The person deletes one. If both stay, the cash balance of that month fails.
- The first statement of an account needs an opening entry with the lots, because the opening table prints no cost. Until December 2025, "Precio ponderado" of a coupon bond included accrued interest. From January 2026, it is the purchase cost.

### Alpaca

The Alpaca pipeline reads the statements of the custodian, never the advisor PDF. `Alpaca::Entry` joins the four tables of the statement into one stream. Its sort keeps the printed order, because a reversal and the rows of a corporate action must stay together. `Alpaca::CorporateAction` handles splits and spinoffs, which keep the cost basis. The removed total wins, because Alpaca rounds the price on the added side. The sign of `quantity` separates removals from additions.

These behaviors are on purpose:

- The pipeline skips `High-Yield Cash Sweep` rows, because they count the cash twice.
- `Journal Entry(Cash)` rows go to `Expenses:FIXME` for a hand edit. Their descriptions are UUIDs, so no rule can match one twice.
- Each statement asserts a closing `balance` for the cash and for each holding. The one gap is a position that is closed during the month.
- The `alpaca` prompt copies `entry_type` as printed. The payee is `payee` from the account block, or Alpaca. So an unknown type gets to the converter and shows as a FIXME.

`Alpaca::Positions` opens the commodity accounts with `"FIFO"` at the start of the period, and closes them from `closing - moved`. Beancount rejects `"AVERAGE"`, and it ignores `booking:` as indented metadata. Do not also declare these accounts in `account_opens`. If a position comes back after a close in an earlier month, `bean-check` finds a collision. To repair it, delete the earlier `close` and the later `open`.

### Reports (`app/reports.rb`, `lib/reports.rb`, `lib/period.rb`)

`Reports` runs `rledger query --no-cache -q -f json` on the main file, so the options, opens, balances and prices are all in. It accepts both row shapes: rledger 0.22 prints objects and 0.24 prints arrays (`Reports.table`). One query takes 0.07 s and 21 MB on the real ledger, so there is no cache. rustledger warns when an account closes with a balance that is not zero, and `-q` keeps that warning off stderr.

Each ledger is the data of its owner, so rledger runs only after `LedgerFiles.all` (`lib/ledger_files.rb`) passes the ledger:

- It walks the main file and every include, at any depth, globs included, as real paths.
- It raises `LedgerFiles::Unsafe` when an `include`, a `document`, or `option "documents"` resolves outside the real path of the ledger. It also raises when a `plugin` is not a built-in plugin of rledger 0.24, or is `document_discovery`, which lists the directories in its config.
- The regexes follow what rledger does, as measured: rledger also follows an indented `include`, and it accepts a tab or a CR between the words.
- A glob include with `[ ] { }`, or any path with `\`, is refused. Ruby's `Dir.glob` reads those characters in another way than rledger's glob, so the walk could check other files than rledger reads.
- `Reports.run` turns `Unsafe` into a `Reports::Error`. `Reports.check` returns it as one `UNSAFE` error at the line to fix, so the badge and the editors show it, and an edit can repair the ledger.
- It refuses a ledger with more than 4 MB of text (`LedgerFiles::MAX_BYTES`), and counts each file before it reads it. rledger needs about 23 MB of memory for each MB of text, plus 10 MB (measured on 0.75 and 3 MB ledgers). The user's ledger is 0.74 MB.
- On the real ledger (150 files), a walk takes 8 to 9 ms. There is no cache, because the stamp of `ledger_errors` sees only `.beancount` files.
- `Reports.safe_capture` holds the ledger's lock from the walk through the rledger run, so no pull or write lands in between.
- rledger runs with `PATH`, `HOME` and `TZ` only, so no secret reaches it. It reads `.rledger.toml` from its working directory. That is the app's directory, so never start rledger inside a ledger.

- `income(from, to)` sums the Income and Expenses postings in the period.
- `balance(at)` values every account on that day. It adds three made-up equity rows, so that Assets − Liabilities = Equity on the page. `Reports::SYNTHETIC` lists them, and they have no journal link.
- The three rows are `Equity:Utilidades-acumuladas` (Income plus Expenses to that day), `Equity:Ganancias-no-realizadas` (cost against market value of the assets) and `Equity:Conversiones` (the rest: old postings in other currencies at the closing rate).
- MXN mode is the default. Both reports convert with `CONVERT(…, 'MXN', date)` at the closing date of the period. A commodity with no price stays in its own column. `?mxn=0` (the "Por moneda" tab) shows each currency as it is.
- `?period=` is `all`, `2026`, `2026-T3` or `2026-09` (`Period`). Any other value means the current year. The balance sheet is a snapshot at the last day of the period, or today while the period runs.
- `?sort=` orders the accounts under each parent by name or by one currency column (`App::REPORT_SORT`).
- On a ledger with no entries, `Reports.first_date` is nil. The pages then show one sentence with the next step, over tables at zero.
- "Actualizar" posts to `/ledger/pull`, pulls, and returns to the report.

`report_query` builds every toolbar link. It keeps `mxn`, `chart` and `sort` on the page where they apply. It keeps the journal filter (`account`, `q`) only between journal pages, so a filter never gets into a report.

#### Journal (`/journal`)

The journal lists the postings behind a report figure, and every amount on the two reports links to it. Its queries use the same date bounds and the same `CONVERT` as `income`, so the matched postings add up to the figure. A figure on the balance sheet is cumulative, so the journal shows its movements, not the figure.

- `?account=` is a prefix: a parent means its subtree, and empty means every account. It must match `[A-Za-z0-9:-]*`, or the answer is 404. This is the trust boundary in front of the query.
- `?q=` filters on payee or narration. `Reports.bql_text` escapes it and turns `'` into `.`, because a BQL string cannot escape a quote.
- `Reports.journal_index` gives one light entry for each transaction. The count, the total, the sort and the charts read it. The page then fetches only its 200 transactions, whole, by `id` (`Reports.journal`).
- The reason is memory. The full journal of every account left Puma at 124 MB, near the cap of 128 MiB at the time. With the index and pages of 200, the same requests end at 67 MB.
- rledger numbers `id` in ledger order, so `[date, id]` keeps the entries of one day in file order.
- With an account, a date sort and no `q`, the page also shows the balance assertions of the period (`Reports.balances`). One query has the account and the amount, the other has the location, and the code zips them. Balances stay out of the index, so the count, the total and the charts do not change.
- On an Assets, Liabilities or Equity account, with a date sort and no `q`, each transaction also shows the balance after it, in the report sign (`journal_running`). The balance starts from `Reports.opening`, the same query as the Saldo chart, and runs over the whole index, so page 2 starts where page 1 ends. Newest first is date-asc reversed, also inside one day, so a row shows the same balance in both orders.
- A row inside the directive of a ledger error gets the red band and the error message.

#### Charts (`app/charts.rb`, `public/charts.js`)

Ground rules:

- A chart exists only when the person asks for it (`?chart=<name>`). A page without it has no chart block, no data and no script.
- Ruby embeds the rows as JSON in `script#chart-data`, and `charts.js` aggregates and draws them with d3. A new chart on the same rows needs JavaScript only.
- A chart that needs other data gets its own query in `Reports`. That query runs only when the chart is on.
- d3 7.9.0 and d3-sankey 0.12.3 are vendored UMD files in `public/`, loaded with deferred script tags. There is no node, no bundler and no CDN. To upgrade, replace the file.
- Every color and font comes from `style.css`, never from attributes set in JavaScript. So dark mode and the palette hold.
- There is no JavaScript test runner, on purpose. Rack tests cover the menu and the JSON, and a person compares the drawing with the page total.

The journal of one account has four charts (`App::CHARTS`): Histograma, Saldo, Subcuentas and Contrapartes. `chart_options` offers Saldo for Assets, Liabilities and Equity, Histograma for the others, and a treemap only with two groups or more. Saldo is off while `q` is set, because the opening balance of a filtered subset means nothing. Saldo has its own query: `Reports.opening` sums the account before the period. Its last point in MXN mode equals the figure on the balance sheet for that period.

In MXN mode, a histogram bar and the journal page that it links to can differ by a few pesos. `CONVERT` prices each period at its own closing date.

Each report has a third tab, Diagrama, in MXN only (`App::DIAGRAMS`). It replaces the tables. `charts.js` measures the chart block on `load`, because a deferred script can run before the stylesheet lays out the page.

- The income statement (`?chart=sankey`) shows a Sankey of the MXN flows, from the income accounts to the expense accounts, plus the net result, so it always balances. A leaf with a negative net (a refund larger than the spend) moves to the other side. A subtree under 1 % of its side folds into "Otras". On phones, the tables show instead.
- The balance sheet (`?chart=icicle`) shows a zoomable icicle of the Assets, at the market value of the sheet. A click on a cell with children zooms in, a click on the first column zooms out, and a leaf links to its journal. Nothing folds, so the zoom can reach each small account. A negative or unpriced asset has no area and is left out, so a parent can be taller than its row in the table. It stays on phones, two columns wide.

#### Errors (`app/errors.rb`)

`Reports.check` runs `rledger check -f json` and keeps each error once, with its code, message, file, first line and end line. `App.ledger_errors` caches the result by the mtime of every `.beancount` file. On the real ledger, the scan takes 3 ms, and the check takes 46 ms and a 20 MB child process. The topbar badge, the journal, the editors and `/errors` all read it.

A failed balance (`E2001`) shows in Spanish with the gap. It links to the journal of its account for the year of the day before the balance. A balance counts what came before its date, and that year also holds the last good balance.

### Infrastructure (`lib/`)

- `LLM` (`lib/llm.rb`) is the seam between providers: the typed errors, one shared `Transport` over `Net::HTTP`, `LLM.client`, `LLM.key_var` and `LLM.report`.
- A client has one method, `extract(pdf_path, spec) -> Hash`. The spec is a `PromptSpec` of the app, and its other keys go to the API as they are. Keys that start with `_` never reach the API.
- Each client writes one `Usage` row per call, before it parses the answer, because the call is paid either way. `Usage::PRICES` is USD per million tokens (input, cached input, output) from the OpenAI price page, which is also micro-dollars per token. A test makes sure that each model in `prompts/` has a price. An unknown model, such as each Anthropic model today, costs 0 with a warning in the job log. The owner of the ledger pays, so the row names the owner. The row also names the upload: the directory of the PDF, `incoming/<token>/`. So a second extraction of one upload counts as a retry. A new provider is one class and one entry in `LLM::PROVIDERS`.
- `usage` has no foreign keys (`db/4_*.sql`). A row outlives its ledger and its user, so the cap still counts the calls of a deleted ledger, and the costs stay for the totals.
- `Usage.cap_micros` is the user's `monthly_cap_micros`, or 3 USD when it is NULL. The month is the calendar month in local time.
- `Ledger.lock(id)` is one reentrant lock per ledger. It covers each git operation and each write to the ledger's files: the job's pull, its writes and commit, the editor saves, the account forms, "Aplicar reglas", "Actualizar", and the reports from the include walk through rledger. It never covers a model call. A read of HEAD or of the origin needs no lock.
- `OpenAIClient` uses the Responses API with the PDF as `input_file`, in background mode with a 2 s poll. The classifier uses the same client.
  - OpenAI sometimes leaves a background response `queued` for good. On 2026-10-26, four of eight stayed queued for 10 to 15 minutes, and the same requests, sent again, finished in 5 to 38 s.
  - So a response still queued after 60 s is cancelled and sent once more. A second one stuck is an `APIError`, so the job fails and can be retried. A response past `LLM_TIMEOUT` is cancelled too, so it never runs and bills later.
- `AnthropicClient` sends one Messages request with the PDF as a `document` block. A `stop_reason` other than `end_turn` is an `APIError`. Neither client uses a Files API.
- `S3` is a small SigV4 client over `Net::HTTP`. `uri_encode` is the only place that turns a space into `%20`. The tests replay two official AWS test vectors.
- `LocalPdfs` has the same four methods as `S3` (`put`, `list`, `presigned_url`, `delete_prefix`) on disk.
- `Ledger.destroy` deletes a ledger in this order: the PDFs under its prefix, then `ledgers/<id>/`, then its rows. The bucket is the step that can fail, and the row stays until the rest is gone, so a second click finishes the delete. It refuses a ledger whose `pdf_prefix` is not `frijolero/ledgers/<id>`. The adopted ledger has `frijolero`, which holds the PDFs of every ledger and the backups. `Users.delete` deletes the rows of a user whose ledgers are gone. The foreign key of `ledgers` refuses it before that.
- `LedgerRepo` runs git as a subprocess (see "Git subprocesses"). `LedgerRepo.for(ledger)` uses the ledger's deploy key (`ledgers/<id>/deploy_key`) when the file exists. The key is the only credential that git gets. A ledger without one has no remote, so its commits stay local. Until 2026-10-26 the first ledger pulled over HTTPS with `GIT_TOKEN`. It moved to a deploy key by hand, and the token went away.
  - With a key, ssh runs with `IdentitiesOnly=yes`, `StrictHostKeyChecking=yes` and `config/known_hosts`. That file holds the published host keys of github.com and gitlab.com. When a host rotates a key, replace its lines.
  - `clone` and `add_remote` accept only `git@<host>:<path>` or `ssh://git@<host>/<path>`, with a host from `config/known_hosts`. This is the trust boundary. A local path or `file://` would clone the ledger of another user from the disk, and `ext::` or a leading `-` would run a command.
  - Every git call runs with `-c core.symlinks=false`, so no checkout or pull makes a symlink, in any ledger. The first ledger and a template ledger have no such line in their config. A symlink from the person's remote could otherwise point an editor's write at another ledger.
  - `clone` clones with `--no-checkout` and refuses a tree larger than 100 MB before it writes the files. A later pull has no size limit.
  - `keygen` makes an ed25519 key with `ssh-keygen`, and refuses to replace a key.
- `NewLedger.prepare(dir)` makes a ledger from `templates/ledger`, or adds the missing files to one that exists. `bin/new-ledger` is a thin script over it.
- `PromptSpec` joins `spec.json`, `instructions.txt` and `schema.json` from `prompts/<type>/`, and adds `_prompt`, the type, for the usage row. `plata` is the Alpaca prompt with the advisor of the user's own account, and `alpaca` the general one.
- `DB` (`lib/db.rb`) is one SQLite connection behind a Monitor, which is reentrant, so a transaction can call `execute`. At boot, each `db/<n>_*.sql` above `PRAGMA user_version` runs in its own transaction. Money is an integer of micro-dollars, never a float.

## Git subprocesses

`GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` override `chdir:`. When they are set, a test that runs git in a temporary directory commits to this repo instead. It happened once. `test/ledger_repo_test.rb` has the regression test.

- In `lib/`, every git call goes through `LedgerRepo#git`. It runs git with a clean environment (`unsetenv_others: true`): `PATH`, `HOME` and `TZ`, plus `GIT_SSH_COMMAND` with a deploy key. So no `GIT_*` variable and no secret of the app reaches git or ssh.
- The tests that run git themselves set every `GIT_*` variable to nil.

Before you commit new code that runs git:

1. Run `GIT_DIR=$(pwd)/.git GIT_WORK_TREE=$(pwd) bundle exec rake test`.
2. Make sure that `git log -1` did not change.

## Operations

- **Deploy.** Kamal 2 with `config/deploy.yml`, which holds the droplet, the host, the image and the bucket. The image is built for amd64 on the laptop. The volume is `frijolero_data:/data`. A deploy takes about 40 s.
- **Secrets.** `.kamal/secrets` gets each secret from a 1Password item with `kamal secrets fetch --adapter 1password`. The Kamal parser has no line continuations, so each command is one line. The fields are `kamal_registry_password`, `openai_api_key`, `session_secret`, `postmark_api_token`, `b2_key_id`, `b2_application_key` and `admin_email`. A missing field fails the deploy. The `kamal secrets fetch` line must name every field that an `extract` line reads. The fetch gets only the fields that it names, and the deploy of the database failed on a field that was missing there. The values that are not secret, `b2_bucket` and `b2_endpoint`, are in `deploy.yml`.
- **1Password.** `kamal` and `ssh` to the droplet work only while the 1Password app is unlocked. The `op` prompt and the SSH agent go through it.
- **Memory.** The cap is 256 MiB. Right after a boot, production uses 35 to 42 MiB of cgroup memory. Ruby keeps the heap of its largest request: after 13 days up, production used 99.6 MiB (81 MiB of heap), with a peak of 120.6 MiB. A report adds an `rledger` child of about 21 MB for about 0.1 s. kamal-proxy refuses a request body over 100 MB (`proxy.buffering.max_request_body`); its default is 1 GB.
- **Image.** `ruby:<version>-slim`, two stages, user `app`, `TZ=America/Mexico_City`. It installs `git` and `openssh-client` (ssh and ssh-keygen, for the deploy keys) and downloads `rledger` with a pinned checksum. `templates/` is in the image, for `NewLedger`. The base image already has `tzdata`. `Gemfile.lock` pins the Bundler that the image ships, so the build installs no other one.
- **Ruby bump.** The version is in three places: `.ruby-version`, `ARG RUBY_VERSION` in the `Dockerfile`, and `Gemfile.lock` (`bundle update --ruby`). The Gemfile reads `.ruby-version`, and Bundler refuses any other patch release. Then run `docker run --rm --platform linux/amd64 ruby:<version>-slim bundle -v` and pin that Bundler with `bundle update --bundler=<it>`.
- **Backups.** `.kamal/hooks/post-deploy` installs a daily backup on the host, as the other apps there do:
  - It copies `bin/backup-host` to `/usr/local/bin/frijolero-backup`, writes the B2 keys to `/etc/frijolero-backup.env` (mode 600), and adds `/etc/cron.d/frijolero-backup`, which runs at 10:15 UTC. The log is `/var/log/frijolero-backup.log`.
  - The hook reads the B2 keys with `kamal secrets print`, so a deploy asks 1Password once more. Never `source .kamal/secrets` in bash. Bash splits the unquoted `$SECRETS` at a space inside a value, and on 2026-10-26 the failed `kamal secrets extract` printed every secret in the deploy output. The hook also strips whitespace from the keys, because `b2_application_key` once had a stray space.
  - The script runs `bin/backup` in the web container and uploads the archive to `frijolero/daily/` in the bucket. A lifecycle rule of the bucket deletes each archive after 30 days (see Bucket rules).
  - The archive (`lib/backup.rb`) holds a copy of the database through SQLite's online backup API, a verified git bundle of each ledger with its origin, and the job logs. It holds no PDFs, no uploads and no deploy keys.
  - `bin/backup` runs in a process of its own, so `Ledger.lock` cannot cover it. git's atomic ref updates keep each bundle whole.
  - `bin/restore <archive> <empty dir>` and `docs/restore.md` are the way back. To run the first backup by hand: `ssh root@<host> /usr/local/bin/frijolero-backup`.
- **Bucket rules.** A B2 bucket keeps every version of a file. An S3 DELETE only hides the file, and the hidden file is still stored and billed. Two lifecycle rules, set by hand in the B2 console, do the real delete. The bucket is shared with other apps, so each rule names a prefix of Frijolero:
  - `frijolero/ledgers/`: delete hidden files 30 days after they are hidden. This covers the PDFs of a deleted ledger and the old versions that "Sobrescribir" leaves.
  - `frijolero/daily/`: hide each archive 30 days after its upload, and delete it 1 day later.
  - So a deleted ledger can come back by hand for 30 days (see `docs/restore.md`), and after that nothing of it is left.
- **Failed jobs.** The PDF stays in `/data/ledgers/<id>/incoming/<token>/`, and the upload shows in the Bandeja. A successful retry removes it, and so does Descartar. Nothing removes a directory without a PDF, which a job that fails after the extraction leaves.

If `kamal` or `ssh` fails with `promptError` or "communication with agent failed", ask the user to run the command with the `!` prefix. If a failed deploy leaves a lock, run `kamal lock release`.

## Tests

- Minitest and rack-test: about 1080 tests in about 24 s. `test/` mirrors `app/` and `lib/`.
- `with_ledger_dir` makes a temporary ledger, in a fresh `DATA_DIR`, the current ledger of the test thread. A setup uses `enter_test_ledger` and `leave_test_ledger`. `with_db_ledger` also writes the owner and the ledger as rows.
- No test writes into `prompts/`: `Config.prompts_dir` is the real folder. Use `test/fixtures/prompts`, or a copy of it in a temporary directory. Web tests call `App` directly, with fake collaborators. `test/app/app_test.rb` and `test/app/isolation_test.rb` load `config.ru`, for the auth and the ledger wiring. A web test gets a page as production serves it with `'SCRIPT_NAME' => LEDGER_ROOT` in the env, and `assert_ledger_links` fails on a link that leaves the ledger.
- `test_helper.rb` sets `RACK_ENV=test` before it loads the app. Sinatra reads the environment when `sinatra/base` loads, and with any other value its host authorization answers 403.
- No test uses the network.
- `Config.accounts` is read on each call and never memoized. The first deploy cached `{}`, because it started before the volume had a ledger.

Some tests commit in a temporary repo, and they read the global git config. If `commit.gpgsign` is on and 1Password is locked, they wait for approval. To prevent this, run `HOME=$(mktemp -d) bundle exec rake test`.

## Known rough edges

1. There is one worker thread per ledger. A second upload to the same ledger waits for the extraction in front of it.
2. A `closed: true` account leaves the dashboard. Its history stays on its page, which Cuentas links to.
3. While a job commits and pushes (a few seconds), the next page that must run the error check waits for the ledger's lock.
4. An upload that was classified at the cap keeps the answer "Límite del mes" after the month changes. The person picks the account and the period by hand.
5. Invitation links count toward the limit of 5 links an hour of that person.

## Data formats

The transaction JSON of the Default pipeline. The other pipelines have their own schemas in `prompts/<type>/schema.json`:

```json
{ "transactions": [ { "date": "2024-01-15", "description": "AMAZON WEB SERVICES", "amount": -50.00,
                      "currency": "MXN", "payee": "optional", "narration": "optional", "expense_account": "optional" } ] }
```

The rules YAML:

```yaml
start_with:                 # description starts with PATTERN
  PATTERN: { payee: "Name", narration: "Text", account: "Expenses:Category" }
  PATTERN2:                 # with a condition: exact amount
    when: { amount: -149 }
    payee: "Name"
    account: "Expenses:Category"
  PATTERN3:                 # list: first matching `when` wins; the entry without `when` is the fallback
    - { when: { amount: -15000 }, payee: "Landlord", account: "Expenses:Rent" }
    - { payee: "Transfer", account: "Expenses:Misc" }
include:                    # description contains PATTERN; same entry shapes
  PATTERN: { account: "Expenses:Food" }
```
