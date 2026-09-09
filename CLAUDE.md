# CLAUDE.md

Guidance for Claude Code in this repository.

## What this is

Frijolero is a Ruby 4.0 web app. It runs Sinatra on Puma, in one process, with no database. It turns bank, card and brokerage statement PDFs into Beancount.

The flow: you upload a PDF. The app finds the account and the period, and you confirm. A background job extracts the transactions with OpenAI, applies YAML rules, writes a `.beancount` file, includes it in the ledger, and commits and pushes. The ledger is a git repo. The PDFs live in Backblaze B2. Version 2.0.0 replaced the CLI. The design record is `docs/webapp-plan.md`. The user docs, in Spanish, are `docs/setup.md`, `docs/ledger.md` and `docs/rules.md`.

## Commits

- Escribe los mensajes de commit en español, simples y concisos.
- Work happens on local `main`. The user pushes when they decide to. Do not open a PR for each change.
- Read "Git subprocesses" before you write code that shells out to git.

## Commands

```bash
bundle exec rake test && bundle exec rubocop      # both must pass before a commit (bin/test runs both)

bin/dev                                            # local app on http://localhost:3000, password x; reads .env (see .env.example)

kamal deploy                                       # for code changes; needs 1Password unlocked (see Operations)
kamal app exec --reuse '<cmd>'                     # run a command in the production container
```

## Where things live

This repo:

```
config.ru        boots app/app.rb
app/             the Sinatra process: App and its route files, Dashboard, Jobs, views/
public/          style.css
lib/             the pipeline, no Sinatra: frijolero.rb is the manifest that requires the rest
templates/       prompts/ and ledger/, the seeds that bin/new-ledger copies; tests read prompts/classify
bin/             dev, test, test_fast, new-ledger
config/          deploy.yml, puma.rb
test/            mirrors app/ and lib/; fixtures/ holds sample statements and test prompts
```

The ledger repo is a private repo on GitHub. `CLAUDE.local.md`, git-ignored, holds its URL, the laptop path, the droplet, the host and the 1Password item. `bin/new-ledger` creates a ledger from `templates/`. The repo has three copies:

| Copy | Path | Who writes |
|---|---|---|
| Laptop | The clone on the laptop (SSH remote) | The user, with hand edits in fava. The fish function `moneys` pulls, runs fava, and commits and pushes on Ctrl-C. It pulls with rebase before each push. |
| Droplet volume | `/data/ledger` in the container (HTTPS remote, `GIT_TOKEN` header) | The app. Each job pulls with rebase first and commits and pushes last. The editors commit on save. `commit_and_push` pulls with rebase again between the commit and the push, because the laptop may have pushed in the meantime. A conflict aborts the rebase and raises, and the commit stays local. |
| GitHub | origin | Nobody directly. |

Layout of the ledger repo (`LEDGER_DIR`). `Config` derives each path from it:

```
transactions.beancount        # LEDGER_MAIN_FILE; inline txns + `include "accounts/AMEX/AMEX 2508.beancount"`
moneys.beancount              # what fava opens; includes transactions, account_opens, balances, prices
account_opens.beancount       # opens for every non-commodity account
config/accounts.yaml          # account key → beancount_account, openai_prompt_type, converter_type, description, closed, cutoff_day
config/rules/<Key>.yaml       # detailer rules, one file per account key (spaces kept: "BBVA TDC.yaml")
config/prompts/<type>/        # spec.json + instructions.txt + schema.json, read on every call
accounts/<Key>/<Key> YYMM.beancount   # + the .json next to it. Period = the month that holds most of the statement's days
```

On the volume, outside the repo: `/data/jobs.jsonl` is the append-only job log. `/data/incoming/<hex>/<original>.pdf` holds one directory per upload. The app removes that directory only when its job succeeds.

In B2, in a bucket shared with other apps: `frijolero/accounts/<Key>/<Key> YYMM.pdf`. `Config.pdf_key` is the only formula for that key, and `Config.pdf_prefix` is the account's directory.

A change to rules, accounts, prompts or model names is a commit in the ledger repo, not a deploy. The app reads those files on each request and each job. The volume gets the change at the next job's pull, or at once with this command:

```bash
kamal app exec --reuse 'bundle exec ruby -Ilib -e "require %q(frijolero); Frijolero::LedgerRepo.new(dir: ENV.fetch(%q(LEDGER_DIR))).pull"'
```

## Environment variables

| Variable | Purpose |
|---|---|
| `LEDGER_DIR`, `LEDGER_MAIN_FILE` | The ledger clone, and the main file name (default `transactions.beancount`). `Config.data_dir` is the parent of `LEDGER_DIR`. |
| `OPENAI_API_KEY`, `OPENAI_POLL_TIMEOUT` | Extraction and classification. The poll timeout default is 900 s. |
| `APP_PASSWORD` | The only credential, checked by the login form; it also signs the 30-day session cookie, so changing it logs every device out. `/up` and static files are outside auth. |
| `B2_ENDPOINT`, `B2_BUCKET`, `B2_KEY_ID`, `B2_KEY` | S3-compatible B2. `B2.from_env` removes whitespace from the keys. A 1Password field once had a stray space. The symptom was `Signature validation failed`, or `400 IncompleteBody` for large bodies. |
| `GIT_TOKEN` | A GitHub fine-grained token with Contents read/write on the ledger repo. It travels as an HTTP header on each git call. It is never written to disk. |
| `PUMA_THREADS` | Thread pool size (3 in production). |
| `RLEDGER` | The rustledger binary for the reports (default `rledger` on PATH). The image ships 0.24.0 in `/usr/local/bin`. `brew install rustledger` on the laptop. |

## Architecture

### Request side (`app/`)

`App` holds the routes. `app.rb` has the settings, the collaborators, the dashboard and the jobs pages. `uploads.rb`, `statements.rb`, `editors.rb`, `accounts.rb` and `reports.rb` reopen the class for the upload flow, the statement page (with the PDF redirect), the rules editor, the Cuentas section and the reports. `app/` is the only place that requires Sinatra; `lib/` is the pipeline. The class has five class-level collaborators with `attr_writer`s, so tests can swap in fakes: `jobs`, `client` (OpenAI), `b2`, `repo` and `reports`. The app builds each one on first use.

`Login` in `app/login.rb` is a small Sinatra app used as middleware in `config.ru` before `App`. It owns `/login` (GET shows the form, POST checks the password), `/logout` (clears the session), and a `before` filter that redirects requests without a valid session to `/login`. `App` and its tests never see auth. The session cookie is signed, httponly, SameSite=Lax, Secure in production only, and lasts 30 days. The "Salir" button in the topbar posts to `/logout`.

Views are standalone ERB pages in Spanish. There is no layout. Each page renders `app/views/_head.erb` through the `head` helper, which takes the title and an optional refresh, and `app/views/_topbar.erb` through the `topbar` helper, which is the wordmark plus Subir, Jobs, Cuentas and Reportes, with `aria-current` on the section that matches the request path. The CSS is `public/style.css`, after the 1975 NASA Graphics Standards Manual: white ground, black type, one heavy rule under the header, thin rules elsewhere, NASA red only on the wordmark and on anything that needs action, NASA blue for links and the primary button. Public Sans everywhere, IBM Plex Mono for Beancount text, dates and amounts. One token set with `light-dark()` covers both color schemes. A status is a glyph plus a word (`.status.<name>`): received and ok ● in green (`--credit`), pending ○ in orange (`--debit`), queued ○ muted, running ◐, missing ▲ in red, failed ■ in red. Under 40rem every table hides its header row and each row becomes a block: the first cell is a `th scope="row"` heading, each `td[data-label]` becomes a label and value line, and an empty cell disappears, so a cell that may be empty must be written without whitespace inside. `Dashboard` computes received, missing, pending or failed for each active account, on each request. Its two columns are the newest period that some account has closed and the one before it. An account closes a statement on `cutoff_day` of each month (31, or unset, for the last day), and that statement belongs to the month 15 days before the closing date, the same rule as the classifier. An account whose cutoff has not arrived shows pending in that column. Corte shows `cutoff_day` from `accounts.yaml`. The job fills it in the first time a confirmed upload carries a printed period end, and never overwrites it, so a hand edit in `/accounts/<Key>/config` wins.

### Cuentas (`app/accounts.rb`)

`GET /accounts` lists the accounts from `accounts.yaml`, open ones first, closed ones last. Each has three links. `/accounts/<Key>` asks B2 for the PDFs under `Config.pdf_prefix` and shows period, upload date, size, a download link, and a link to the statement page when the `.beancount` exists. Every period between the oldest PDF and the newest one the account has closed (`Dashboard.last_closed`, from `cutoff_day`) gets a row; a period with no PDF shows `falta` with a link to `/upload`. A B2 failure renders the page with the error and status 502. `/accounts/<Key>/config` edits only that account's block of `accounts.yaml`. `AccountBlock` cuts the block by line range, from `Key:` to the next column-0 line, so the comments in the rest of the file survive. The save validates the block, splices it, validates the whole file, and commits `accounts <Key>`. The key of the block cannot change. `/accounts/new` is a form for one Default-pipeline account: key, description, Beancount account, prompt type from the `config/prompts` directories, optional cutoff day and opening date. `NewAccount` in `lib/` validates it, appends a block to the end of `accounts.yaml`, appends `<date> open <account>` to `account_opens.beancount` unless a line already opens that account, and commits `cuenta <Key>`. The other pipelines need extra accounts, so they go through `/accounts/yaml`, the whole-file editor. The routes for `yaml` and `new` are defined before `/accounts/:key` on purpose.

### Upload flow

`POST /upload` saves the PDF under `incoming/` and runs `Classifier` in the request. If the file name parses as `<Key> YYMM.pdf`, the classifier answers without OpenAI. If not, it makes one OpenAI call with the `classify` prompt. It fills the account enum from `AccountConfig.descriptions`, makes sure that the dates are plausible, and derives `YYMM` from the midpoint of `period_start` and `period_end`, so the period is the month that holds most of the statement's days (AMEX Aug 4 to Sep 3 is `2608`). A doubtful result becomes `unknown`. The page then shows the result, and the person confirms. `POST /upload/confirm` validates the form and pushes a job. The second button, "Solo guardar PDF", posts to `POST /upload/backup`, which puts the PDF in B2 inside the request and removes the upload. It skips OpenAI, the ledger and the job log. It is for a statement whose `.beancount` already exists.

### Job

`Jobs` is one `Queue`, one worker `Thread` and `jobs.jsonl`. At boot it marks jobs left in `running` or `queued` as `failed`. There are no retries. The job body is: `repo.pull`, then `Statement#process`, then `repo.commit_and_push("<Key> YYMM")`, then remove the upload directory. The body runs with `Log.sink` pointed at the job output.

### `Statement`

`Statement` owns one PDF. The steps, in order: resolve account and period (arguments first, file name as fallback). Refuse if the outputs exist and `overwrite` is false. Upload to OpenAI, or reuse `file_id`. **Put the PDF in B2.** Extract. **Run `pipeline.validate!`.** Delete the local PDF. Save the JSON. Detail (Default pipeline only, and only if a rules file exists). Convert. Merge. Delete the OpenAI file.

The order protects the PDF. B2 has it before the paid step. The local copy survives each failure. Errors go through `OpenAIErrorReporter`, a policy table with one entry per `OpenAIClient::Error` subclass, and the result is `ERROR`. The job then fails with that status in its message.

### `Pipeline`

`Pipeline.for(account_config)` selects `Default`, `CetesDirecto`, `Fintual` or `Plata` from `converter_type`. A strategy gives the summary line, tells if the detailer runs (`runs_detailer?`), owns `validate!`, and calls its converter. Only `Default` has rules. For the other pipelines the rules links, the rules editor and the detail button are gone, and `/rules/<Key>` is a 404. `validate!` raises `Pipeline::InvalidData` and names the missing table or field. Only `Default` rows have `date`, `description` and `amount`. The statement page shows those rows as a list, one entry per transaction: date, merchant, the rest of the description muted, payee, narration and account or a red `sin clasificar` with the Hacer regla button, and the amount with thousands separators and a sign, green for credits and orange for debits (`money` and `split_description` in `app.rb`; the split is at the first `; ` or before an AMEX `RFC…` token, display only). The list and the Beancount text are two tabs made of two radio inputs and `:has()`, no script. For the other pipelines the page shows only the summary and the Beancount text. The Beancount text is colored by `beancount_html` in `statements.rb`, one regex over the escaped text: dates and comments muted, the flag bold and orange when it is `!`, accounts blue, `Expenses:FIXME` red, amounts green or orange by sign. Strings are matched only so that their contents stay plain. A line that matches nothing is plain text, so a hand edit never breaks the page. There is no highlighting library. A new statement type is one strategy plus one converter.

### Rules loop

`Detailer::Rules` is the pure matcher: `start_with`, `include`, an optional `when.amount`, and arrays with a fallback. `Detailer` applies it to the JSON. `BeancountDetailer` applies it again to an existing `.beancount` file. It touches only transactions that still post to `Expenses:FIXME`, so it is idempotent and hand edits are safe. Transactions with the `!` flag are invisible to it. `POST /statements/:k/:yymm/detail` runs it and commits only if something changed.

The rules editor validates with `YAML.safe_load` and a probe call to `matches_for`. "Hacer regla" prefills a `start_with` entry with `YAML.dump`. That dump drops comments and reorders keys. This is accepted, but it is visible on a 600-line file. "Hacer regla" also sends the statement path as `back`. The editor shows it as a "Volver al estado de cuenta" link and keeps it in a hidden field, and the save redirects there with `?rules=1`, which the statement page turns into a notice asking to run the rules again. `back_path` honours only `/statements/<Key>/<YYMM>`.

### Converters

`Converters::Default`, `CetesDirecto`, `Fintual` and `Plata` inherit from `Base` and share `AccountTargets` and `Amounts`. All amounts go through `BigDecimal`. A Float residue such as `-5.55e-17` breaks Beancount. `Amounts#money` and `Amounts#number` write thousands with commas (`-15,596.89 MXN`, `11,042 PORTMAN-E10F`). Beancount reads them, `bean-check` was run on a sample to confirm, and `Beancount::Transaction` strips them when it parses an amount back. `BeancountMerger` appends an `include` line relative to the directory of the main file.

### Plata reads Alpaca statements, never the advisor PDF

`Plata::Entry` flattens the four tables of the statement into one stream. The sort is stable on printed order, because reversals and the rows of one corporate action must stay adjacent. `Plata::CorporateAction` handles splits and spinoffs. They conserve cost basis. The removed total is authoritative, because Alpaca rounds the price on the added side. The sign of `quantity` separates removals from additions.

Three behaviours are deliberate. `High-Yield Cash Sweep` rows are skipped, because they double-count. `Journal Entry(Cash)` rows go to `Expenses:FIXME` for a hand edit, because their descriptions are UUIDs that no rule would match twice. A closing `balance` is asserted for cash and for each holding. A position exited mid-month is the one gap.

`Plata::Positions` opens commodity accounts with `"FIFO"` at the period start and closes them from `closing - moved`. Only commodity accounts are managed this way. Never declare them in `account_opens` too. A re-entry after a close in a later month collides at `bean-check`. The fix is to delete the earlier `close` and the later `open`. Commodity accounts must be `"FIFO"`. Beancount rejects `"AVERAGE"`, and `booking:` as indented metadata is ignored. The `plata` prompt copies `entry_type` verbatim, so an unknown type reaches the converter as a visible FIXME.

### Reportes (`app/reports.rb`, `lib/reports.rb`, `lib/period.rb`)

`/reports/income` and `/reports/balance` are whole-ledger reports. `Reports` runs `rledger query --no-cache -q -f json` (rustledger, a static binary; `Config.rledger`) on `moneys.beancount` (`Config.report_file`, the fava entry point, so options, opens, balances and prices are in), one BQL query per page plus `first_date`, and parses the JSON rows into `{account => {currency => BigDecimal}}`. Both row shapes are accepted: 0.22 prints objects, 0.24 arrays. `income(from, to)` sums Income and Expenses postings in the interval. `balance(at)` values every account on that day and folds Income plus Expenses up to it, negated, into one `Equity:Utilidades-acumuladas` row. Both take `mxn:`, on by default: the total is `SUM(CONVERT(position, 'MXN', date))` at the closing date of the period (the income statement too, not per posting), which prices stocks through USD, and a commodity with no price stays in its own column. With `mxn: false` they are `SUM(position)` and `VALUE(SUM(position), at)`. `?mxn=0` on the page picks that, the "Por moneda" tab in the toolbar, and `report_query` carries it through every toolbar link and the period menu. `tree` adds the parent accounts with subtotals, in tree order, and leaves out accounts at zero. The views show one column per currency seen, income and liabilities with the sign flipped, and the two sections side by side from 60rem. Only the first level under each root is visible at load; a parent's name is a button and `public/reports.js` (the one script in the app) shows its direct children or hides and resets its subtree.

The span comes from `?period=`: `all`, `2026`, `2026-T3` or `2026-09`, parsed by `Period`; anything else means the current year. The income statement covers the period; the balance sheet is a snapshot at its last day, or today while it is still running. The title row is the two report names side by side, the current one as the `h1` and the other a light link at the same size, then the clone's last commit as "Datos actualizados al" (`LedgerRepo#head`, subject in the tooltip) and an "Actualizar" button that posts to `/ledger/pull`, runs `repo.pull` and returns to the report with `?pull=ok`, or with the git error in `pull`. The toolbar under it has the four resolutions (switching keeps the anchor date: from 2024 to Mes lands on December 2024), ‹ › around a menu of every period between `Reports.first_date` and today (the menu submits on change through `reports.js`), "al <today>" while the period is still running, and the currency tabs pushed to the right. That is the third way the droplet's clone catches up with the laptop, besides a job's first pull and the pull inside every commit. Measured on the real ledger: 0.07 s and 21 MB per query, so there is no cache. rustledger is stricter than Python beancount on one point: it warns when an account closes with a non-zero balance; `-q` keeps that off stderr and the query still runs.

### Infrastructure classes

`OpenAIClient` has a nested `Transport` and typed errors. `extract_transactions(file_id, spec)` runs any prompt spec on a file, with `background: true` and a 2 s poll. The classifier uses it too. `B2` is a hand-rolled SigV4 client over `Net::HTTP`, with path-style URLs. `list(prefix)` reads one page of ListObjectsV2 and parses the XML with a regex. `uri_encode` is the only place that turns a space into `%20`. The tests replay two official AWS vectors. `LedgerRepo` runs git as a subprocess (see "Git subprocesses"). `Log` writes plain lines to `Log.sink`. `PromptSpec` assembles `spec.json`, `instructions.txt` and `schema.json`. The templates live in `templates/prompts/{default,plata,classify}`. The ledger repo holds the live copies, and `bbva`, `cetes` and `fintual` exist only there.

## Git subprocesses

`GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` override `chdir:`. If they are set, a test that runs git "in a tmpdir" commits to this repo instead. It happened once. Each git subprocess, in lib and in tests, gets an env hash that sets every `ENV` key that matches `/\AGIT_/` to nil. `LedgerRepo#git` does this, and `test/ledger_repo_test.rb` has the regression test. Before you commit new code that touches git, run `GIT_DIR=$(pwd)/.git GIT_WORK_TREE=$(pwd) bundle exec rake test` once and make sure that `git log -1` did not move.

## Operations

- **Deploy.** Kamal 2 with `config/deploy.yml`, which holds the droplet, the host, the image and the bucket. The image is built for amd64 on the laptop. The volume is `frijolero_data:/data`. The memory cap is 128 MiB.
- **Secrets.** `.kamal/secrets` fetches each secret from a 1Password item with `kamal secrets fetch --adapter 1password`. Write one command per line, because the Kamal parser has no line continuations. The fields are `kamal_registry_password`, `openai_api_key`, `app_password`, `b2_key_id`, `b2_application_key` and `git_token`. The non-secret `b2_bucket` and `b2_endpoint` are copied into `deploy.yml`.
- **From the shell of Claude,** `kamal` and `ssh` to the droplet work only while the 1Password app is unlocked. The `op` prompt and the SSH agent both go through it. If they fail with `promptError` or "communication with agent failed", ask the user to run the command with the `!` prefix. A failed deploy can leave a lock. `kamal lock release` removes it.
- **Measured.** Idle production memory is 35 to 42 MiB of cgroup memory, or 46 to 52 MB of RSS. A report adds a ~21 MB `rledger` child for ~0.1 s. The cap is 128 MiB. A deploy takes about 40 s.
- **Dockerfile.** `ruby:4.0.6-slim`, two stages, user `app`, with `git` installed for `LedgerRepo` and the `rledger` binary (downloaded with a pinned checksum in the build stage) for the reports. `Gemfile.lock` pins Bundler to 4.0.16, the version in the image.
- **Failed job.** The job page shows the captured output. The PDF stays in `/data/incoming/<hex>/`. There is no retry from disk. The person uploads again. Stale directories accumulate, and nothing removes them yet.

## Tests

Minitest and rack-test, about 520 tests, about 5 s. `test/` mirrors `app/` and `lib/`. `with_ledger_dir` points `LEDGER_DIR` at a temporary directory with `config/`. Web tests call `App` directly and swap the collaborators for fakes. Only `test/app/app_test.rb` loads `config.ru`, for the auth wiring. `test_helper.rb` sets `RACK_ENV=test` before it loads the app; Sinatra fixes its environment when `sinatra/base` loads, and any other value makes host authorization return 403 in tests. No test touches the network. `Config.accounts` is read on each call and never memoized. The first deploy cached `{}` because it booted before the volume had a ledger.

## Known rough edges

1. `POST /upload` blocks on the classifier: background mode plus a 2 s first poll. Two options: a synchronous Responses call with `reasoning.effort: minimal`, or a classify job with a page that refreshes. The model is `gpt-5.4-mini`, set in `config/prompts/classify/spec.json` of the ledger.
2. One worker thread. A second upload waits behind an extraction.
3. "Hacer regla" rewrites the whole rules file and drops comments.
4. A `closed: true` account leaves the dashboard. Its history lives on its page under Cuentas.

## Data formats

Transaction JSON for the Default pipeline. The other pipelines have their own schemas in `config/prompts/<type>/schema.json`:
```json
{ "transactions": [ { "date": "2024-01-15", "description": "AMAZON WEB SERVICES", "amount": -50.00,
                      "currency": "MXN", "payee": "optional", "narration": "optional", "expense_account": "optional" } ] }
```

Rules YAML:
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
