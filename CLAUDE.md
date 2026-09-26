# CLAUDE.md

Guidance for Claude Code in this repository. The code shows what each part does. This file gives what the code does not show: the layout outside the repo, the decisions and their reasons, and the traps.

## What this is

Frijolero is a Ruby 4.0 web app. It turns statement PDFs from banks, cards and brokers into Beancount. It runs Sinatra on Puma in one process, with no database.

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

bin/dev                                          # the app on http://localhost:3000, password x; reads .env (see .env.example)
bin/demo-ledger tmp/demo --persona contractor --income 65000   # a fake ledger with three banks, 24 months, rules, PDFs and a job log
LEDGER_DIR=tmp/demo/ledger bin/dev               # the app on that fake ledger

kamal deploy                                     # deploy a code change; needs 1Password unlocked (see Operations)
kamal app exec --reuse '<cmd>'                   # run a command in the production container
```

Without `LEDGER_REPO` in `.env`, `bin/dev` keeps a ledger in `~/.local/share/frijolero`. It stops before Puma when the main file of the ledger is missing.

## Where things live

This repo:

```
config.ru     starts App behind the Login middleware
app/          the Sinatra process: App, its route files, Dashboard, Jobs, views/
public/       style.css, reports.js, editor.js, charts.js, and the vendored d3 files
lib/          the pipeline, with no Sinatra; lib/frijolero.rb requires the rest
templates/    prompts/ and ledger/, the seeds that bin/new-ledger copies
bin/          dev, test, test_fast, new-ledger, demo-ledger
config/       deploy.yml, puma.rb
test/         mirrors app/ and lib/; fixtures/ holds sample statements and prompts
```

### The ledger repo

The ledger is a private repo on GitHub. `CLAUDE.local.md` (git-ignored) has its URL and the other private values. `bin/new-ledger` creates a ledger from `templates/`. On an existing ledger, it adds only the missing `config/` files.

The ledger has three copies:

| Copy | Where | Who writes |
|---|---|---|
| Laptop | A clone with an SSH remote | The user, by hand: pull with rebase, commit, push. |
| Droplet | `/data/ledger` in the container, HTTPS remote | The app: jobs, editors and rule runs. |
| GitHub | origin | Nobody directly. |

The app keeps its copy in sync like this:

- Each job pulls with rebase before it starts, and commits and pushes at the end.
- `LedgerRepo#commit_and_push` pulls with rebase again between the commit and the push, because the laptop can push in the meantime.
- A rebase conflict aborts the rebase and raises. The commit stays local.
- A clone with no remote (a setup on the laptop only) skips the pull and the push.
- The "Actualizar" button on the report pages runs a pull.

Layout of the ledger (`LEDGER_DIR`). `Config` derives each path from it:

```
main.beancount            LEDGER_MAIN_FILE: options, opens, and one `include` per statement
account_opens.beancount   optional; when it exists, new `open` lines go here and not in the main file
config/accounts.yaml      account key → beancount_account, openai_prompt_type, converter_type, description, cutoff_day, closed
config/rules/<Key>.yaml   the rules of one account; the name keeps spaces ("BBVA TDC.yaml")
config/prompts/<type>/    spec.json, instructions.txt, schema.json; read on each model call
accounts/<Key>/<Key> YYMM.beancount   and the .json next to it
```

`YYMM` is the month that holds most of the days of the statement. The user's own ledger is older than the template. Its main file is `moneys.beancount` (set in `deploy.yml`), and it includes other files. Beancount does not care which file holds an entry, so the app appends to the main file.

A change to the rules, the accounts, the prompts or the model names is a commit in the ledger, not a deploy. The app reads those files on each request and each job. The droplet gets the change at its next pull. To pull from the shell:

```bash
kamal app exec --reuse 'bundle exec ruby -Ilib -e "require %q(frijolero); Frijolero::LedgerRepo.new(dir: ENV.fetch(%q(LEDGER_DIR))).pull"'
```

### Outside the ledger

On the volume (`/data`, the parent of `LEDGER_DIR`):

- `jobs.jsonl`: the append-only job log.
- `incoming/<token>/<original name>.pdf`: one directory for each upload. A successful job removes it.
- `pdfs/`: the PDFs, when no bucket is set.

In the bucket, which other apps share: `frijolero/accounts/<Key>/<Key> YYMM.pdf`. `Config.pdf_key` is the only formula for that key.

## Environment variables

| Variable | Purpose |
|---|---|
| `LEDGER_DIR`, `LEDGER_MAIN_FILE` | The ledger clone, and the name of its main file (default `main.beancount`). |
| `LLM_PROVIDER`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` | `LLM_PROVIDER` is `openai` (default) or `anthropic`. Without the key of that provider, `LLM.client` is nil and the app cannot classify or extract. The model names are in the `spec.json` files of the ledger, so a change of provider changes them too. |
| `LLM_TIMEOUT` | Default 900 s. It is the poll deadline for OpenAI and the read timeout for Anthropic. |
| `APP_PASSWORD` | The only credential. It also signs the session cookie (30 days), so a new password logs out every device. |
| `S3_ENDPOINT`, `S3_BUCKET`, `S3_KEY_ID`, `S3_KEY` | Any S3-compatible store (B2 in production). The endpoint is a bare host. With none of the four, the PDFs go to disk (`LocalPdfs`). With only some, `S3.from_env` raises and names the missing ones. It also removes whitespace from the keys: a stray space from 1Password once caused `Signature validation failed`. |
| `S3_REGION`, `S3_PATH_STYLE` | Optional. The default region is the second segment of the endpoint, which is correct for B2 and AWS. R2 needs `auto`, Hetzner its location, and DigitalOcean and MinIO `us-east-1`. `S3_PATH_STYLE=1` puts the bucket in the path, for MinIO on localhost or a bucket name with a dot. |
| `GIT_TOKEN` | A GitHub fine-grained token with Contents read and write on the ledger. Each git call sends it as an HTTP header. It is never written to disk. |
| `PUMA_THREADS` | The size of the thread pool (3 in production). |
| `RLEDGER` | The rustledger binary for the reports and the error check (default `rledger` on the PATH). The image has 0.24.0. On the laptop: `brew install rustledger`. |
| `TZ` | `America/Mexico_City`, set in the Dockerfile. `Date.today` and the job times follow it. |

## Architecture

### Request side (`app/`)

- `app/app.rb` holds the settings, the collaborators, the dashboard and the job pages. Each other file in `app/` reopens `App` for one area. `app/` is the only place that requires Sinatra.
- `App` has five collaborators, each built on first use: `jobs`, `client`, `s3`, `repo` and `reports`. Tests replace them through their `attr_writer`.
- `Login` (`app/login.rb`) is middleware in front of `App`. It owns `/login` and `/logout`, and it sends each request without a session to `/login`. `App` and its tests never see auth. `/up` and the static files are outside it.
- The views are standalone ERB pages in Spanish, with no layout. Each page calls the `head` and `topbar` helpers.
- All pages of one account are under `/accounts/<Key>`. A statement has three URLs: `/accounts/<Key>/<YYMM>` (the movements), `…/beancount` (the text) and `…/beancount/edit` (the text in the editor). The route constraints in `app/statements.rb` keep `config` and `rules` out of the period segment.
- With no account in `accounts.yaml`, a filter sends every `/upload` route to `/accounts/new`. So no model call can happen before the first account exists.

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
- `/accounts/new` adds one account for the Default pipeline. `NewAccount` appends the block and an `open` line, unless a line already opens that account. The other pipelines need extra accounts, so they use `/accounts/yaml`, the editor for the whole file.

### Upload flow (`app/uploads.rb`)

1. `POST /upload` saves the PDF in `incoming/<token>/` and runs `Classifier` in the request.
2. A file name like `<Key> YYMM.pdf` needs no model. Any other name costs one model call with the `classify` prompt. Without a model key, the route answers 422 and names the key variable.
3. The classifier takes the period from the midpoint of the printed start and end, so AMEX Aug 4 to Sep 3 is `2608`. A doubtful answer becomes `unknown`.
4. The confirm page shows the result. If that statement exists and a model key is set, the page says so and shows the Sobrescribir box. Without overwrite, the job refuses an existing statement.
5. "Procesar" (`POST /upload/confirm`) queues a job. "Solo guardar PDF" (`POST /upload/backup`) puts the PDF in the bucket during the request and removes the upload. It skips the model, the ledger and the job log.

The buttons that wait on the server have `data-busy`. `reports.js` writes that word on the button and makes the form `inert`, so a second click sends nothing. The `pageshow` event restores them when the back button shows the page from the cache.

### Jobs (`app/jobs.rb`)

`Jobs` is one `Queue`, one worker thread and `jobs.jsonl`. At boot, it marks the jobs left `running` or `queued` as failed. The job body is `repo.pull`, then `Statement#process`, then `repo.commit_and_push("<Key> YYMM")`, then the removal of the upload directory. The body writes its output through `Log.sink`. The UI calls a job a "corrida".

A failed job shows "Reintentar" only when a model key is set and `retryable_upload` is true:

- The job has an upload token. Jobs logged before the token existed have none.
- The account still exists.
- The `.beancount` of that statement does not exist. A later success for the same label ends the retry.
- The upload directory still holds the PDF. `Statement` deletes it after the extraction, so a retry is possible only after a failure at the extraction, such as a 429.

The retry runs with overwrite off and does not record the cutoff day. The job log stores times in UTC. The pages show them in local time, with the status words in Spanish.

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

### Pipelines (`lib/pipeline.rb`)

`Pipeline.for(account_config)` selects a strategy from `converter_type`: `Default`, `Multi`, `CetesDirecto`, `Fintual` or `Alpaca` (`plata` is the old name of `alpaca`). A strategy gives the summary line, owns `validate!`, can change the extraction request, and calls its converter. A new statement type is one strategy and one converter.

Only `Default` and `Multi` have rules. For the other pipelines there are no rule links, no rules editor and no "Aplicar reglas", and `/accounts/<Key>/rules` is a 404.

`Multi` is a `Default` for one PDF that covers several accounts at one bank, each in a section "Movimientos de <name>". The `accounts` map in `accounts.yaml` connects each printed name to a Beancount account. The `account` enum of the schema holds only the printed names, so the model never sees a Beancount name. A transfer between two of those accounts appears once in each section. When a rule points a row at another account of the same statement, `Multi#convert` drops the mirror row (same date, opposite amount).

### Statement page (`app/statements.rb`)

The page reads the `.beancount` file, not the JSON. The JSON is fixed at job time, but the rules, the edit dialog and hand edits change the file. `StatementRows` takes the amount from the source posting (on `beancount_account`, or on an account of a Multi). The other postings are the classification, and `Expenses:FIXME` means unclassified.

- The movements and the Beancount text are two views, each at its own URL. The server renders only the current view.
- The date of a movement opens the edit dialog on that transaction (see Editors). So a person can classify one movement without a rule.
- "▲ N sin clasificar" links to `#sin-clasificar`, the first unclassified row. While that row is the `:target`, CSS highlights every `li.fixme`. There is no script.
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

- `LedgerEdit` checks `file` and `line`. A path outside `LEDGER_DIR`, or a file that is not `.beancount`, is a 404. This is the trust boundary.
- `line` can point at any line of a transaction, and `LedgerEdit` walks back to its header. No `line` means the whole file.
- If the block no longer matches the `original` that the form sent, the answer is 409. A job or a pull changed the file.
- The save runs `Reports.check` before and after the write. It puts the file back and answers 422 only when the edit adds errors, counted by code and file. So a person can repair a ledger that has errors one edit at a time.
- A clean check commits and pushes. A git failure is 502, and the file stays saved and committed locally.
- There is no lock against the job worker.

rledger prints real paths. `Reports.ledger_file` makes them relative to the real path of `LEDGER_DIR`, because `bin/dev` gets to the ledger through a symlink.

The account autocomplete lists `LedgerAccounts.active`: the `open` lines minus the `close` lines. A name that only a rule uses, or a closed account, fails the check. The list opens only where an account goes (`BEANCOUNT_SPOT`, `RULES_SPOT` and `ACCOUNTS_SPOT` in `editor.js`). It is a script because a textarea cannot use a `<datalist>`.

### Converters (`lib/converters/`)

Every amount goes through `BigDecimal`, because a float residue such as `-5.55e-17` breaks Beancount. `Amounts` writes thousands with commas (`-15,596.89 MXN`). Beancount accepts them, and `Beancount::Transaction` removes them when it reads an amount back. `BeancountMerger` adds an `include` line, relative to the directory of the main file.

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
- The reason is memory. The full journal of every account left Puma at 124 MB, near the cap of 128 MiB. With the index and pages of 200, the same requests end at 67 MB.
- rledger numbers `id` in ledger order, so `[date, id]` keeps the entries of one day in file order.
- With an account, a date sort and no `q`, the page also shows the balance assertions of the period (`Reports.balances`). One query has the account and the amount, the other has the location, and the code zips them. Balances stay out of the index, so the count, the total and the charts do not change.
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

The income statement has a third tab, Diagrama (`?chart=sankey`). It is a Sankey of the MXN flows, from the income accounts to the expense accounts, plus the net result, so it always balances. A leaf with a negative net (a refund larger than the spend) moves to the other side. A subtree under 1 % of its side folds into "Otras". On phones, the tables show instead. `charts.js` measures the chart block on `load`, because a deferred script can run before the stylesheet lays out the page.

#### Errors (`app/errors.rb`)

`Reports.check` runs `rledger check -f json` and keeps each error once, with its code, message, file, first line and end line. `App.ledger_errors` caches the result by the mtime of every `.beancount` file. On the real ledger, the scan takes 3 ms, and the check takes 46 ms and a 20 MB child process. The topbar badge, the journal, the editors and `/errors` all read it.

A failed balance (`E2001`) shows in Spanish with the gap. It links to the journal of its account for the year of the day before the balance. A balance counts what came before its date, and that year also holds the last good balance.

### Infrastructure (`lib/`)

- `LLM` (`lib/llm.rb`) is the seam between providers: the typed errors, one shared `Transport` over `Net::HTTP`, `LLM.client`, `LLM.key_var` and `LLM.report`.
- A client has one method, `extract(pdf_path, spec) -> Hash`. The spec is the `PromptSpec` of the ledger, and its other keys go to the API as they are. A new provider is one class and one entry in `LLM::PROVIDERS`.
- `OpenAIClient` uses the Responses API with the PDF as `input_file`, in background mode with a 2 s poll. The classifier uses the same client.
- `AnthropicClient` sends one Messages request with the PDF as a `document` block. A `stop_reason` other than `end_turn` is an `APIError`. Neither client uses a Files API.
- `S3` is a small SigV4 client over `Net::HTTP`. `uri_encode` is the only place that turns a space into `%20`. The tests replay two official AWS test vectors.
- `LocalPdfs` has the same three methods as `S3` (`put`, `list`, `presigned_url`) on disk.
- `LedgerRepo` runs git as a subprocess (see "Git subprocesses").
- `PromptSpec` joins `spec.json`, `instructions.txt` and `schema.json`. The templates are in `templates/prompts/`. The ledger holds the live copies, and some prompts (`bbva`, `cetes`, `fintual`) exist only there.

## Git subprocesses

`GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` override `chdir:`. When they are set, a test that runs git in a temporary directory commits to this repo instead. It happened once. So each git subprocess, in `lib/` and in the tests, gets an env hash that sets every `GIT_*` variable to nil. `LedgerRepo#git` does this, and `test/ledger_repo_test.rb` has the regression test.

Before you commit new code that runs git:

1. Run `GIT_DIR=$(pwd)/.git GIT_WORK_TREE=$(pwd) bundle exec rake test`.
2. Make sure that `git log -1` did not change.

## Operations

- **Deploy.** Kamal 2 with `config/deploy.yml`, which holds the droplet, the host, the image and the bucket. The image is built for amd64 on the laptop. The volume is `frijolero_data:/data`. A deploy takes about 40 s.
- **Secrets.** `.kamal/secrets` gets each secret from a 1Password item with `kamal secrets fetch --adapter 1password`. The Kamal parser has no line continuations, so each command is one line. The fields are `kamal_registry_password`, `openai_api_key`, `app_password`, `b2_key_id`, `b2_application_key` and `git_token`. The values that are not secret, `b2_bucket` and `b2_endpoint`, are in `deploy.yml`.
- **1Password.** `kamal` and `ssh` to the droplet work only while the 1Password app is unlocked. The `op` prompt and the SSH agent go through it.
- **Memory.** The cap is 128 MiB. Idle production uses 35 to 42 MiB of cgroup memory. A report adds an `rledger` child of about 21 MB for about 0.1 s.
- **Image.** `ruby:4.0.6-slim`, two stages, user `app`, `TZ=America/Mexico_City`. It installs `git` and downloads `rledger` with a pinned checksum. The base image already has `tzdata`. `Gemfile.lock` pins Bundler 4.0.16, the version in the image.
- **Failed jobs.** The PDF stays in `/data/incoming/<token>/`. A successful retry removes it. Nothing removes the other old directories yet.

If `kamal` or `ssh` fails with `promptError` or "communication with agent failed", ask the user to run the command with the `!` prefix. If a failed deploy leaves a lock, run `kamal lock release`.

## Tests

- Minitest and rack-test: about 750 tests in about 12 s. `test/` mirrors `app/` and `lib/`.
- `with_ledger_dir` points `LEDGER_DIR` at a temporary ledger. Web tests call `App` directly, with fake collaborators. Only `test/app/app_test.rb` loads `config.ru`, for the auth wiring.
- `test_helper.rb` sets `RACK_ENV=test` before it loads the app. Sinatra reads the environment when `sinatra/base` loads, and with any other value its host authorization answers 403.
- No test uses the network.
- `Config.accounts` is read on each call and never memoized. The first deploy cached `{}`, because it started before the volume had a ledger.

Some tests commit in a temporary repo, and they read the global git config. If `commit.gpgsign` is on and 1Password is locked, they wait for approval. To prevent this, run `HOME=$(mktemp -d) bundle exec rake test`.

## Known rough edges

1. `POST /upload` waits for the classifier during the request: OpenAI background mode, with a first poll after 2 s. There are two options: a synchronous Responses call with `reasoning.effort: minimal`, or a classify job with a page that refreshes. The classify model is set in `config/prompts/classify/spec.json` of the ledger.
2. There is one worker thread. A second upload waits for the extraction in front of it.
3. A `closed: true` account leaves the dashboard. Its history stays on its page, which Cuentas links to.

## Data formats

The transaction JSON of the Default pipeline. The other pipelines have their own schemas in `config/prompts/<type>/schema.json`:

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
