# Frijolero Web: plan

Status: draft, reviewed twice. Nothing in this document is built yet.

Today the monthly routine is: download the PDFs, run the CLI, and fix the
FIXME rows in fava. The goal is to do this routine from a web page on any
device. The PDFs and the ledger must live in a place that is more reliable
than a laptop plus iCloud.

## 1. Decisions

- **Same repo, version 2.0.** The CLI is retired. The domain code and its
  tests stay. See "Retire the CLI".
- **Stack.** Sinatra on Puma, one process, one worker thread, no database.
  The filesystem is the database. Measured memory is in section 2.
- **Ledger.** A private GitHub repo is the origin. The droplet and the laptop
  are clones. The droplet is the only writer of pipeline output. The laptop
  is the only place for hand edits.
- **Configuration.** It moves into the ledger repo, in a directory named
  `config/`. See "Configuration" for the layout. The OpenAI key and all
  paths become environment variables. The file `config.yaml` disappears.
- **PDFs.** They live in B2, and only in B2. The app keeps a local copy only
  while it works on the file. Downloads are short-lived signed links to B2.
- **Classification.** Bank apps give the PDFs meaningless names. The app asks
  OpenAI for the account and the period, with the same model as the default
  extractor (`gpt-5`). You confirm before the extraction starts.
- **Deployment.** Kamal 2 on the droplet `maia`, next to four other apps. The
  droplet has 2 GB of RAM and about 1 GB free. The hostname is
  `frijolero.pati.to`. Ruby is `4.0.6`, pinned in `.ruby-version`.
- **All accounts are monthly.**
- **The ledger repo** is new, at `~/Developer/beancount-ledger`. It starts
  as a copy of the current files in `~/Documents/Beancount`, without the
  backups, the cache, and the PDFs. The main file is `transactions.beancount`.
  The old directory stays until you delete it. It holds 39 MB, and 129 PDFs
  are most of that.
- **File names.** Per-account files live under `accounts/`, and the name is
  the account key, a space, and the period: `accounts/AMEX/AMEX 2508.beancount`.
  The JSON sits next to it. See "Data".

### Why a web app and not a shell script

The two stated problems have cheaper solutions. A git repo solves the iCloud
problem in one afternoon. A rules editor, not a configuration editor, solves
the YAML problem, because only the rules change often.

The web app is worth the work for what comes on top:

1. **Upload from anywhere.** Bank app, share sheet, frijolero. No laptop.
2. **The monthly checklist.** "September: Amex received, BBVA missing."
   Today you keep this list in your head.
3. **Rules with a feedback loop.** You see a FIXME row. You click "make this
   a rule". You run detail again. The FIXME row is gone.
4. **A path to an online ledger.** When the ledger lives on the server, a
   viewer next to it is a small next step.

The cost: one more app to keep alive, and financial documents behind a login
on the public internet. One user, TLS, and a long random password make the
second acceptable.

### Why not a rewrite in a new repo

The expensive part of the gem is small but subtle: four converters, the
beancount parser with surgical FIXME edits, and the OpenAI error policy. The
tests are an executable spec of that work. A rewrite solves the same
problems a second time. What a new repo offers, a `git rm` of the CLI offers
cheaper.

Configuration stays as YAML in the ledger repo, because git then gives a
diff, a history, and a backup of each rule change for free. SQLite earns its
place when a search needs an index or a second user arrives. Neither is in
v1.

## 2. Stack

### Memory, measured

Linux containers, RSS after `GC.start`:

| Process                                     | Ruby 3.4 | Ruby 4.0.6 slim |
|---------------------------------------------|----------|-----------------|
| bare `ruby -e ''`                           | 12 MB    | 14 MB           |
| + sinatra + puma (+ yaml, json, net/http)   | 30 MB    | 30 MB           |
| serving 100 requests plus one HTTPS call    | 34 MB    | 39 MB           |

Measured on the droplet after the first deploy (2026-09-05, `ruby:4.0.6-slim`,
amd64, after boot and about 20 requests): 41.9 MiB of cgroup memory, 51.5 MB
`VmRSS`, cap 64 MiB.

The frijolero code adds a few MB. A job holds one PDF in memory during the
upload (1 MB to 3 MB, temporary). The expected steady state is **about
45 MB**. The cap in Kamal is 64 MB. Then an overrun is a visible restart, not
a slow squeeze.

Rejected for memory: Rails (100 MB or more), `aws-sdk-s3` (heavy, and SigV4
is 60 lines of standard library), ActiveSupport, a second Ruby process, and
Redis.

Rejected for effort: Go and Rust. They save 30 MB that you do not need and
rewrite four converters and their tests.

### Deployment

```yaml
# config/deploy.yml
service: frijolero
image: jaimerodas/frijolero
servers:
  web:
    - maia
proxy:
  ssl: true
  host: frijolero.pati.to
  healthcheck: { path: /up }
volumes:
  - frijolero_data:/data
env:
  clear:
    LEDGER_DIR: /data/ledger
    MALLOC_ARENA_MAX: "2"
    WEB_CONCURRENCY: "0"      # puma single mode
    PUMA_THREADS: "3"
  secret:
    - OPENAI_API_KEY
    - APP_PASSWORD
    - B2_KEY_ID
    - B2_KEY
    - GIT_TOKEN                # GitHub fine-grained token, HTTPS remote
options:
  memory: 64m
```

Dockerfile: `ruby:4.0.6-slim`, the version in `.ruby-version`. Then
`apt-get install git build-essential` (Puma compiles a native extension),
then `bundle install --without development test`, then `CMD puma`.

Environment variables that the app reads:

| Variable            | Meaning                                   | Default                  |
|---------------------|-------------------------------------------|--------------------------|
| `LEDGER_DIR`        | The clone of the ledger repo              | required                 |
| `LEDGER_MAIN_FILE`  | The main file, relative to `LEDGER_DIR`   | `transactions.beancount` |
| `OPENAI_API_KEY`    |                                           | required                 |
| `APP_PASSWORD`      | The one password for basic auth           | required                 |
| `B2_ENDPOINT`, `B2_BUCKET`, `B2_KEY_ID`, `B2_KEY` | The S3-compatible endpoint of B2 | required |
| `GIT_TOKEN`         | Push access to the origin over HTTPS      | required                 |

Everything else derives from `LEDGER_DIR`.

## 3. Design

### Configuration

The directory `config/` at the root of the ledger repo:

```
config/
  accounts.yaml        # statement type → beancount accounts, prompt type, converter, description
  rules/               # was detailers/. One file per account: rules/AMEX.yaml
  prompts/             # one folder per prompt type, as today: default/, plata/, classify/
```

It is not hidden, because you edit these files, and the laptop gets them
with each pull. "Rules" is what the files hold and what the web page calls
them. A rules file has the same name as its account key.

What is gone: `config.yaml`. Its keys were the OpenAI key (now an environment
variable), paths (now derived from `LEDGER_DIR`), and the input directory for
PDFs (now `incoming/`, see "Data").

New key in `accounts.yaml`: `description`, for classification. For example,
"BBVA checking account (cuenta de débito), MXN".

### Functions (v1)

1. **Dashboard.** Shows the current month and the previous month for each
   account: received, missing, or failed. "Missing" means that the file
   `accounts/{Account}/{Account} {YYMM}.beancount` does not exist. A statement arrives
   in the month after its period. Thus the app judges "missing" against the
   previous month.
2. **Upload.** A form with the PDF and an `overwrite` checkbox. The app
   classifies the PDF and shows the result: "AMEX Aeromexico, 2508.
   Correct?" You confirm or change the account and the period. Then the app
   creates a job and sends you to the job page.
3. **Job page.** Shows the status and the captured pipeline output. The page
   refreshes while the job runs. On success it links to the statement.
4. **Statement page.** Shows the pipeline summary, the transactions from the
   JSON, the FIXME count, the beancount preview, and a PDF download. The
   download is a signed B2 link that expires after 10 minutes. Two actions:
   "run detail again" and "make a rule from this transaction".
5. **Rules editor.** One per account. A text area over `rules/{Account}.yaml`.
   On save, the app makes sure that `Detailer::Rules.load` does not raise.
   "Make a rule" fills in a new `start_with` entry. A save through
   `YAML.dump` removes comments. This is accepted.
6. **Accounts editor.** A text area over `accounts.yaml`, with the same
   validation. You use it a few times per year.
7. **Login.** `Rack::Auth::Basic` with one password from the environment.
   TLS comes from kamal-proxy.

Not in v1: transaction search (grep the JSON directory), transaction edits in
the browser (the existing review page, later), an online ledger viewer, more
than one user, passkeys, and notifications.

### Data

```
/data                              # Kamal volume
  ledger/                          # git clone, origin = private GitHub repo
    transactions.beancount         # the main file, includes the per-account files
    account_opens.beancount
    .gitignore                     # *.bak*, *.cache
    config/                        # configuration, see above
    accounts/
      AMEX/
        AMEX 2508.beancount
        AMEX 2508.json
      AMEX Aeromexico/
        AMEX Aeromexico 2508.beancount
        AMEX Aeromexico 2508.json
  jobs.jsonl                       # append-only job log, one line per state change
  incoming/                        # one PDF per running job, deleted when the job ends
```

The file name is the account key, one space, and the period. This is the
convention of the input PDFs today (`AMEX 2508.pdf`), so one rule covers
everything: the period is the last word, the account key is the rest. The
underscores of today's names and the `canonical_account_name` logic that
maps them back to `accounts.yaml` both go away.

The B2 bucket holds the PDFs with the same relative path: the key of
`AMEX 2508` is `accounts/AMEX/AMEX 2508.pdf`. A space in a key is legal, but
the SigV4 canonical request must encode it as `%20`, in both the upload and
the signed download URL. Package 4.3 has a test for exactly this. There is
no `pdf/` directory on the volume or in the repo. A one-time upload moves
the PDFs in `~/Documents/Beancount` to B2.

To download a PDF, the app signs a B2 URL (SigV4 query parameters, valid for
10 minutes) and redirects the browser to it. The same signer produces the
upload signature.

The app computes the status of a statement on each request. It never stores
the status. The status has three parts: the beancount file exists, the main
file includes it, and the count of `Expenses:FIXME` postings in it. With
about 12 files per month, this stays instant for years.

### Classification

The same bank can issue a card statement, a checking statement, and an
investment statement. The `description` of each account is what separates
them.

`prompts/classify/` is one more prompt folder, loaded by `PromptSpec` like
the others. Its `spec.json` copies the model of the default extractor. Its
schema has three fields. `account` is an enum of the keys in `accounts.yaml`,
plus `unknown`. `period_start` and `period_end` are the printed dates of the
statement period, as `YYYY-MM-DD`. The enum comes from `accounts.yaml` at
request time, so the model cannot invent an account.

The period of a statement is the month in which it closes. A statement that
runs from April 23 to May 22 is `2605`. So is the AMEX statement that runs
from April 2 to May 3, even though most of its days are in April. This is
the label that the bank prints on the statement, and the rule that the
current file names already follow, for every account. The app derives `YYMM` from
`period_end` in code. The model reads a date that is printed on the
statement, and does no calendar reasoning of its own. The confirmation page
shows both dates next to the result, so a wrong read is visible: "BBVA,
2026-04-23 to 2026-05-22, period 2605. Correct?"

If a bank changes its closing day, two statements can close in the same
month. Then the second upload finds an existing file, and the `overwrite`
checkbox is the decision. This is rare, and the app does not try to be
clever about it.

Safety measures:

- The PDF goes to OpenAI once. The extraction reuses the same file id. The
  app deletes the file from OpenAI at the end of the job.
- The app makes sure that `period_end` is plausible: after `period_start`,
  not in the future, and not more than 24 months in the past. Otherwise the
  result is `unknown`.
- You confirm the result before the app writes anything or pays for the
  extraction. If the result is `unknown`, you pick both values by hand.
- A parseable filename (`AMEX 2508.pdf`) skips the call.
- OpenAI does not train on API data by default. Zero data retention is a
  request to OpenAI, not a code change.

Rejected for v1: local text extraction with `pdftotext` plus text patterns.
It needs poppler in the container, hand-found patterns per bank, and fails
on a scanned PDF. A classification call costs a fraction of a cent.

### Job lifecycle

```
1. upload → incoming/<random>.pdf → Classifier (one OpenAI call, file uploaded once)
2. confirmation page: account + period, you confirm or correct
3. Queue.push(job); worker thread:
     git pull --rebase                  (abort the job if this fails; show the error)
     B2.put("accounts/AMEX/AMEX 2508.pdf")   the PDF is safe before the expensive work
     UI.auto_accept = true; UI.sink = job.log
     extract transactions (OpenAI, same file id) → validate JSON
     delete incoming/<random>.pdf       only after the JSON is valid
     save JSON → detail → convert → merge (Statement, as today)
     delete the file at OpenAI
     git add -A && git commit -m "AMEX 2508" && git push
     append {id, status, finished_at} → jobs.jsonl
```

The order protects the PDF. B2 has it before the extraction starts. The
local copy stays until the JSON is valid. If the extraction fails, the job
page shows the error and the local PDF stays for a retry.

"Valid JSON" means: the response parses, it has a `transactions` array, and
each row has a date, a description, and an amount. The pipeline strategy
(`Pipeline.for`) already knows what a statement of each type must contain,
so the check lives there.

One `Thread` reads one `Queue`. The app starts the thread at boot. At boot,
the app marks each job that is still `running` in `jobs.jsonl` as `failed`.
There are no retries. You upload the PDF again.

### Routes

```
GET  /up                         health
GET  /                           dashboard
GET  /upload                     form
POST /upload                     classify → confirmation page
POST /upload/confirm             → 303 /jobs/:id
GET  /jobs                       log
GET  /jobs/:id                   status + output (meta refresh while running)
GET  /statements/:account/:yymm  statement page
POST /statements/:account/:yymm/detail        run the rules again
GET  /statements/:account/:yymm/pdf           302 to a signed B2 URL
GET  /rules/:account             editor
POST /rules/:account             save (validate first)
POST /rules/:account/from        "make a rule" prefill
GET  /accounts                   accounts.yaml editor
POST /accounts                   save
```

### The laptop side: the `moneys` function

`moneys` becomes the only way that you touch the repo on the laptop. You
never type a git command.

At start: if uncommitted edits exist, commit them, rebase, and push. If none
exist, pull. Then run fava. At stop (Ctrl-C, as today): commit and push. The
pull at start happens in both cases, because the droplet adds statements
between sessions and fava must show them.

The problem with Ctrl-C: when a foreground job dies from Ctrl-C, fish
cancels the rest of the function. Six ways around this were tested at a real
interactive fish 4.8 prompt:

| Variant                                              | Push runs |
|------------------------------------------------------|-----------|
| Plain function                                       | no        |
| fava inside `sh -c 'trap "exit 0" INT; ...'`         | yes       |
| fava inside a fish subshell with a trap              | yes       |
| fava in the background, then `wait`                  | no        |
| A fish `--on-signal INT` handler                     | no        |
| fava in the background, then a `read` prompt         | yes       |

The choice is the `sh` wrapper. Fava behaves exactly as today, and Ctrl-C
still stops it. The wrapper catches the interrupt after fava exits and
returns 0. Then fish continues with the push.

```fish
# ~/.config/fish/functions/moneys.fish
# Start: commit any leftover edits, pull with rebase, push if anything is
# waiting. Then run fava. Stop (Ctrl-C): commit and push; if the remote moved
# during the session (the droplet added a statement, or you saved rules in
# the web app), pull once more and push again. The sh wrapper catches the
# interrupt and exits with 0, so fish does not cancel the function.

function moneys --description 'Pull the ledger, run fava, push your edits'
    set -l repo $MONEYS_REPO
    _moneys_commit $repo; and echo "moneys: committed edits left over from the last session"
    _moneys_sync $repo
    touch $repo/.git/MONEYS_DIRTY
    sh -c 'trap "exit 0" INT; cd "$1" && uv run fava "$2"' _ $MONEYS_FAVA_DIR $repo/moneys.beancount
    _moneys_commit $repo
    if _moneys_sync $repo
        rm -f $repo/.git/MONEYS_DIRTY
    else
        echo "moneys: push failed. Edits are committed locally. Run moneys again to push." >&2
    end
end

function _moneys_commit --argument-names repo
    git -C $repo add -A
    git -C $repo diff --cached --quiet; and return 1
    git -C $repo commit -qm "Edits from fava "(date +%Y-%m-%d)
end

# Pull with rebase, then push whatever is ahead of the remote. Returns 1 only
# when a push was needed and failed.
function _moneys_sync --argument-names repo
    git -C $repo pull --rebase -q; or echo "moneys: pull failed, working offline" >&2
    test (git -C $repo rev-list --count @{u}..HEAD 2>/dev/null; or echo 0) -gt 0; or return 0
    git -C $repo push -q
end
```

```fish
# ~/.config/fish/conf.d/moneys.fish
#
# Defaults for the moneys function, and a warning at the prompt when a fava
# session ended without a push (a closed window, a failed push).

set -q MONEYS_REPO; or set -g MONEYS_REPO ~/Developer/beancount-ledger
set -q MONEYS_FAVA_DIR; or set -g MONEYS_FAVA_DIR ~/Developer/custom-fava

function _moneys_warn --on-event fish_prompt
    test -e $MONEYS_REPO/.git/MONEYS_DIRTY; or return
    pgrep -qf "fava $MONEYS_REPO/moneys.beancount"; and return
    set_color yellow; echo "moneys: ledger edits are not pushed. Run moneys."; set_color normal
end
```

On 2026-09-05 the first real session hit a rejected push: the web app had
committed "rules AMEX" while fava was open. The function now pulls with
rebase before every push, so a remote that moved during the session is
integrated instead of rejected.

The warning covers what the trap cannot: a closed terminal window, or a
failed push. Then the file `.git/MONEYS_DIRTY` stays, and each new prompt
shows a yellow line until a run of `moneys` pushes. The warning stays silent
while fava runs.

Tested end to end in a scratch repo with a bare origin and the real fava.
The clone had a leftover uncommitted edit at start. A second edit happened
during the session. After Ctrl-C, both commits were at the origin and the
dirty flag was removed.

### Retire the CLI

The web app replaces the CLI. Nothing that stays depends on the files that
go, except `Statement`, which loses the overwrite prompt. Git keeps the
history.

The new file layout also removes code: `Statement#output_paths`,
`BeancountMerger`, `BeancountDetailer`, and `AccountConfig` all build or
parse the `Account_YYMM` names with underscores. They change to the
`accounts/{Account}/{Account} {YYMM}` rule in package 1.2.

Files that go (about 1,900 lines):

- `bin/frijolero`, `lib/frijolero/cli.rb`, and all of `lib/frijolero/cli/`.
- `lib/frijolero/layout_migrator.rb` and `lib/frijolero/layout_migrator/`.
- `lib/frijolero/statement_processor.rb`. The app processes one PDF per job.
- `lib/frijolero/account_renamer.rb`, `lib/frijolero/transaction_splitter.rb`,
  and `lib/frijolero/beancount/main_file_writer.rb` (the splitter is its only
  user).
- `lib/frijolero/csv_converter.rb`.
- `lib/frijolero/json_statement_summary.rb`. It only fed the overwrite prompt.
- `lib/frijolero/templates/{config,accounts,detailer}.yaml`. The examples
  move to the README. The prompts in `lib/frijolero/templates/prompts/` stay.
- The tests of each deleted file.
- The dependencies `cli-ui`, `reline`, `csv`, and `rackup`. `puma` comes in.

Files that stay: `config.rb`, `prompt_spec.rb`, `account_config.rb`,
`accounts.rb`, `detailer.rb`, `detailer/rules.rb`, `beancount_detailer.rb`,
`openai_client.rb`, `openai_error_reporter.rb`, `converters/`, `pipeline.rb`,
`beancount/` (parser, quoting, header, transaction), `beancount_merger.rb`,
`statement.rb`, `ui.rb` (smaller), `web/`, and their tests.

## 4. Work packages

Each package is one pull request with its own tests. The suite and rubocop
must be green at the end of each. A package names the agent tier for its
complexity. The orchestrator (Fable) reviews each package before merge and
does the integration work between packages.

Tiers: **haiku** for mechanical work with a clear list, **sonnet** for
self-contained code with tests, **opus** for changes to the pipeline core
or code where a subtle error costs money or data.

### Milestone 1: retire the CLI and prepare the gem

| # | Package | Tier | Depends on |
|---|---------|------|------------|
| 1.1 | Delete the files in "Retire the CLI", their tests, and the four dependencies. Add `puma`. Make sure that `require "frijolero"` still loads and that the suite is green. | haiku | |
| 1.2 | `Config` reads `LEDGER_DIR` and `LEDGER_MAIN_FILE`. The configuration directory is `LEDGER_DIR/config`. Rules live in `rules/`. Delete `config.yaml` support and the methods that only the CLI used. One function gives the path of a statement file from an account key and a period, under `accounts/`, with the space. `Statement`, `BeancountMerger`, `BeancountDetailer`, and `AccountConfig` use it. Update the tests. | sonnet | 1.1 |
| 1.3 | `UI` loses `cli-ui`. It writes plain lines to a sink (`UI.sink = io`). `confirm` returns `auto_accept`. Frames and spinners become one line each. Update `ui_test.rb`. | sonnet | 1.1 |
| 1.4 | `config.ru`, Puma settings from `PUMA_THREADS`, `Rack::Auth::Basic` from `APP_PASSWORD`, and `GET /up`. `Web::App` becomes the app. The old review routes stay, unused. | sonnet | 1.2 |
| 1.5 | Rewrite the README for the app. Move the example YAML files into it. | haiku | 1.1 |

### Milestone 2: classification

| # | Package | Tier | Depends on |
|---|---------|------|------------|
| 2.1 | `prompts/classify/` in the templates: `spec.json` (model from the default extractor), `instructions.txt`, `schema.json` with a placeholder enum. `AccountConfig` reads `description`. | sonnet | 1.2 |
| 2.2 | `Classifier`: upload, one request with the enum filled from `accounts.yaml`, `YYMM` from `period_end`, plausibility check of the dates, `unknown` on doubt. Tests with a fake transport, including a period that spans two months. | sonnet | 2.1 |
| 2.3 | `Statement` accepts `account:` and `period:` as inputs, with the filename as the fallback. It accepts a file id that is already uploaded. Remove the overwrite prompt in favor of an `overwrite:` argument. | opus | 1.3 |
| 2.4 | One run by hand against a real badly named PDF from `Pending Statements`. Record the result in the PR. | orchestrator | 2.2, 2.3 |

### Milestone 3: skeleton on the droplet

| # | Package | Tier | Depends on |
|---|---------|------|------------|
| 3.1 | `Web::Jobs`: one `Queue`, one `Thread`, `jobs.jsonl` writer, boot recovery of `running` jobs. Tests with a fake job body. | sonnet | 1.4 |
| 3.2 | `Web::Dashboard`: expected against present, per account, for two months. Pure code with tests. The view. | sonnet | 1.2 |
| 3.3 | Upload flow: `GET /upload`, `POST /upload` (classify, confirmation page), `POST /upload/confirm` (job), `GET /jobs`, `GET /jobs/:id`. The job body calls `Statement`. | sonnet | 2.3, 3.1 |
| 3.4 | `Dockerfile` and `config/deploy.yml`. First deploy. Measure RSS in the container for one day with `droplet-status`. This is the go or no-go point for the memory budget. | sonnet, deploy by the orchestrator | 3.3 |

### Milestone 4: durability

| # | Package | Tier | Depends on |
|---|---------|------|------------|
| 4.1 | A one-time script that builds `~/Developer/beancount-ledger` from `~/Documents/Beancount`: copy the ledger files (no backups, cache, or PDFs), move each `Account_YYMM.beancount` and its JSON to `accounts/{Account}/{Account} {YYMM}.*`, rewrite the `include` lines in the main file, copy `~/.frijolero` into `config/` (rename `detailers/` to `rules/`, one file per account key, remove `config.yaml`), add the `.gitignore`. The script is idempotent and does not touch the source directory. | sonnet | |
| 4.1b | By hand: run 4.1, make sure that fava loads the result with no errors, push to a new private GitHub repo, clone on the volume. | orchestrator with the user | 4.1, 3.4 |
| 4.2 | `Web::LedgerRepo`: `pull`, `commit_and_push`, with `git` as a shell command and `GIT_TOKEN` in the remote URL. Tests against a scratch bare repo. | sonnet | 3.1 |
| 4.3 | `B2`: `put` and `presigned_url` with SigV4 over `Net::HTTP`, in the shape of `OpenAIClient::Transport`. One test against a known AWS signature test vector. One test with a key that has a space, to make sure that the canonical URI encodes it as `%20`. One test with a fake transport. | opus | |
| 4.4 | `Statement` in the order of "Job lifecycle": B2 upload before the extraction, JSON validation in the pipeline strategy, local delete after a valid JSON, OpenAI file delete at the end. Wire 4.2 and 4.3 into the job body. | opus | 4.2, 4.3 |
| 4.5 | `GET /statements/:account/:yymm/pdf` redirects to a signed URL. | haiku | 4.3 |
| 4.6 | A one-time script that uploads the 129 PDFs from the laptop to B2 with the right keys. Run by the orchestrator. | haiku | 4.3 |
| 4.7 | Install the two `moneys` files from this document. | haiku | 4.1b |

### Milestone 5: the rules loop

| # | Package | Tier | Depends on |
|---|---------|------|------------|
| 5.1 | Statement page: summary, transactions from the JSON, FIXME count, beancount preview, PDF link. | sonnet | 4.5 |
| 5.2 | `POST /statements/:account/:yymm/detail` calls `BeancountDetailer`, then commits and pushes. | haiku | 5.1, 4.2 |
| 5.3 | Rules editor: `GET`/`POST /rules/:account` with validation, and `POST /rules/:account/from` with the prefill. Commits and pushes on save. | sonnet | 5.1 |
| 5.4 | Accounts editor: `GET`/`POST /accounts` with validation. | haiku | 5.3 |

Later, on demand: transaction search, transaction edits in the browser,
backup of `jobs.jsonl` to B2, and an online ledger viewer.

## 5. Open questions

None at this time.
