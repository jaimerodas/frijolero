# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Frijolero is a Ruby web app that processes bank and credit card statement PDFs. OpenAI extracts the transactions from each PDF, and rules enrich them. The app converts the result to Beancount accounting format and adds it to a ledger.

## Commits

- Escribe los mensajes de commit en español
- Mantenlos simples y concisos

## Commands

```bash
# Run tests + rubocop (also wired into script/test and script/test_fast)
bundle exec rake test
bundle exec rubocop

# Run the app locally
LEDGER_DIR=... APP_PASSWORD=... OPENAI_API_KEY=... bundle exec puma -C config/puma.rb config.ru

# Image and deploy (Kamal 2; secrets come from the shell, see .kamal/secrets)
docker build -t frijolero .
kamal deploy

# Build gem
gem build frijolero.gemspec
```

## Architecture

**Gem structure:** All code lives under `lib/frijolero/` within the `Frijolero` module.

**File layout:** `LEDGER_DIR` is a git repo. `Config` derives every other path from it and from `LEDGER_MAIN_FILE`:

```
ledger_dir/                     # LEDGER_DIR
  transactions.beancount        # LEDGER_MAIN_FILE (default name); includes each account file
  config/
    accounts.yaml
    rules/
      Amex.yaml
    prompts/
      default/
        spec.json
        instructions.txt
        schema.json
  accounts/
    Amex/
      Amex 2501.beancount       # canonical, included by the main file
      Amex 2501.json
```

There is no `config.yaml` file. Every setting comes from an environment variable. A statement file name is an account key, one space, and a period as `YYMM`. The period is the month the statement closes, not the month you upload it.

**Processing pipeline:**
1. `Statement` owns one PDF's lifecycle: resolve account and period → check overwrite → upload (or reuse `file_id:`) → **save the PDF to B2** → extract → **`pipeline.validate!`** → delete the local PDF → save JSON → detail → convert → merge → delete the OpenAI file. The order is the point: B2 has the PDF before the paid extraction, and the local copy survives every failure, so a failed job leaves a retry on disk. The caller passes `account:`, `period:`, `file_id:`, `overwrite:` and an optional `b2:`; without `b2:` the PDF is neither uploaded nor deleted. The filename is only the fallback for account and period. There are no prompts: convert and merge always run.
1a. `Classifier` decides account and period for a PDF. A parseable known filename answers with no OpenAI call. Otherwise it uploads once, runs the `classify` prompt with the account enum and the account list filled from `accounts.yaml`, checks that the dates are plausible, and derives `YYMM` from `period_end`. Anything doubtful becomes `unknown`, and the person confirms before the paid extraction.
2. `OpenAIErrorReporter` is the error-handling policy table — maps each `OpenAIClient::Error` subclass to `{recoverable:, report:}` and is invoked from `Statement#run_pipeline`'s single rescue clause.
3. `Pipeline.for(account_config)` returns a strategy (`Pipeline::Default`, `CetesDirecto`, `Fintual`, or `Plata`) that knows how to summarize the extracted data, whether to run the detailer, and which underlying converter to call. Adding a new bank statement type means adding one strategy class plus one converter — no edits to `Statement`. Each strategy also owns `validate!(data)`, which raises `Pipeline::InvalidData` naming the missing table or field (`transactions[3] lacks amount`); `Statement` calls it before it deletes the local PDF, so a bad extraction never costs the source document.
4. `Detailer` enriches transactions using YAML rules (only for `Default` pipeline). The matching itself lives in `Detailer::Rules` — a pure engine over the YAML that knows nothing about JSON — so `BeancountDetailer` can reuse it to re-run the rules against an already-converted `.beancount` file. That closes the loop where you notice a missing rule while cleaning up `Expenses:FIXME` rows in fava: add the rule, re-run the detailer on the `.beancount`, no need to go back to the JSON and redo the conversion and merge. `BeancountDetailer` only ever rewrites transactions still posting to `Expenses:FIXME`, which both protects hand edits and makes the run idempotent. It edits surgically via `Beancount::Transaction` (header line + the one FIXME posting), so hand-added metadata, comments and extra postings survive verbatim. Known limitation, inherited from `Beancount::Parser::TRANSACTION_RE` (which matches only the `*` flag): a transaction flagged `!` is invisible to the detailer — it is neither detailed nor counted in `remaining`, so the summary under-reports if you flag a row `!` in fava while leaving it on `Expenses:FIXME`.
5. `Converters::Beancount` / `Converters::CetesDirecto` / `Converters::Fintual` / `Converters::Plata` convert enriched JSON to Beancount format (invoked by the pipeline strategy). All four inherit from `Converters::Base` (output path resolution, `convert`/`run_to(io)` template). `Converters::AccountTargets` is the value object that bundles `counterpart`/`interest`/`tax`/`dividend`/`gains`/`fees`/`withholding`/`opening` so converters take three keyword args instead of ten. `Converters::Amounts` is the shared number mixin — all parsing goes through `BigDecimal`, because Float turns an exact reconciliation into a residue like `-5.55e-17` that renders in scientific notation and that Beancount's parser rejects.

**The Plata converter reads Alpaca brokerage statements, not the advisor's.** `Plata Investments` is a US brokerage account custodied at Alpaca and held through a Mexican advisor. The advisor also issues its own Spanish summary statement; that document is incomplete (dividends reported net of withholding, no transfer detail, corporate actions invisible) and the converter was rewritten in 0.10.0 to read the Alpaca statement instead. Do not point this pipeline back at the advisor PDF. The Alpaca statement reconciles exactly — every Cash Summary line is reproducible from the four detail tables to the cent — and that property is what the converter and its tests are built on.

Its structure: `Plata::Entry` flattens the statement's four detail tables (Transaction, Income, Fees, Deposit & Withdrawals) into one date-ordered stream. The sort is *stable on printed position*, which matters twice — a dividend booked, reversed and rebooked on one date must keep that order, and the rows of one corporate action must stay adjacent so the converter can group them. `Plata::CorporateAction` handles `Stock Split` and `Stock SpinOff`: they conserve cost basis, but Alpaca's printed per-share price on the new side is rounded (NFLX 5 @ 480.46 = 2402.30 becomes 50 @ 48.05, which multiplies back to 2402.50), so the *removed* total is authoritative and additions are allocated against it, the largest absorbing the residue. The sign of `quantity` — never the description text — separates removals from additions, because a spinoff's target row carries neither the word ADD nor REMOVE.

Three Plata behaviours are deliberate and easy to "fix" wrongly: `High-Yield Cash Sweep` rows are skipped (they move cash between the brokerage and the FDIC partner banks, are absent from the Cash Summary, and emitting them double-counts); `Journal Entry(Cash)` rows are booked to `Expenses:FIXME` flagged `*` so `BeancountDetailer` can resolve them from a rules file, because their counterpart is genuinely not in the statement; and a closing `balance` assertion is emitted for cash *and every holding*, which is what replaced the old `UnitReconciler` share-count guesswork. A position exited mid-month drops out of the Holdings table, so it cannot be asserted to zero — that is the one gap the assertions do not cover.

**Commodity accounts are opened and closed by the converter, not by hand.** `Plata::Positions` recovers each symbol's opening count as `closing - moved` — the statement never states it, but it reports the closing count and every movement that produced it. A symbol whose opening count is zero gets an `open ... "FIFO"` dated at period start; one whose closing count is zero gets a `close` dated with the balance assertions; a symbol bought and sold inside one month gets both. A symbol is only considered if it has share movements this period, which is what stops a dividend for a position exited months ago (it carries no quantity) from reading as an exit. A split must not trip this: it removes the whole position and adds it back under the same symbol, so opening and closing are both non-zero.

Consequences worth knowing: **only commodity accounts are managed this way** — Cash, income, expense and equity accounts outlive any one statement and stay in the ledger's `account_opens` file — and declaring a Plata commodity account in both places is a duplicate-open error. The real limitation is re-entry: beancount refuses to reopen a closed account, so a position exited in one month and repurchased in a later one produces a colliding `close`/`open` pair across two files. It fails loudly at `bean-check` (`Account ... is already open` plus `Posting to inactive account`) and the fix is to delete the earlier `close` and the later `open`. No converter can detect it, because a converter only ever sees one month.

**Beancount booking methods:** the investment converters emit `{}` reductions on sales, which are ambiguous under Beancount's default STRICT booking once a commodity has more than one lot. Commodity accounts must therefore be opened with FIFO — `2025-01-01 open Assets:Investments:Plata:AAPL AAPL "FIFO"`. `"AVERAGE"` is not a substitute: real Beancount rejects it outright (`AVERAGE method is not supported`) and rustledger silently zeroes the position on any reduction. Note that a `booking: "AVERAGE"` line indented under an `open` is *metadata*, silently ignored — the method belongs on the open line itself.
6. `BeancountMerger` appends an `include` line to the main ledger, pointing at the canonical converter output — no file copy. The path in the `include` line is relative to the main file's directory.
7. `OpenAIClient` handles PDF upload/extraction via OpenAI API. HTTP transport, auth, and error mapping live in nested `OpenAIClient::Transport`; the outer class is a thin domain layer over it. Errors surface as typed exceptions: `AuthenticationError`, `InsufficientQuotaError`, `RateLimitError`, `APIError`, `NetworkError`.
8. `UI` writes plain lines to `UI.sink` (`$stdout` by default). The web app can point `UI.sink` at a job log. `confirm` has no terminal to ask, so it always returns `UI.auto_accept?`.
9. `Accounts` parses a beancount file for account names (autocomplete support in the browser review UI).
10. `Web::App` is the Rack/Sinatra app. `config.ru` mounts `GET /up` without auth (kamal-proxy health check) and everything else behind `Rack::Auth::Basic` with `APP_PASSWORD`, and starts the job worker at boot. `config/puma.rb` runs single mode with `PUMA_THREADS`. Routes live in three files that reopen the class: `app.rb` (dashboard, upload, confirm, jobs, PDF redirect), `web/statements.rb` (statement page, re-run rules) and `web/editors.rb` (rules and accounts editors). The class holds four lazily built collaborators with `attr_writer`s so tests can swap fakes: `jobs`, `client` (OpenAI), `b2`, `repo`. Views are standalone ERB pages in Spanish with inline CSS; there is no layout.
11. `Web::Jobs` is one `Queue`, one worker `Thread` and an append-only `jobs.jsonl` (one line per state change). The job body runs with `UI.sink` pointed at the job's output and `UI.auto_accept = true`. At boot, jobs left `running` or `queued` are marked `failed`. There are no retries.
12. `Web::Dashboard` computes, on each request, whether each account's statement exists for the previous and the current month (`received`, `missing`, `pending`, `failed`). Nothing is stored. Data paths: `Config.data_dir` is the parent of `LEDGER_DIR`; `jobs.jsonl` and `incoming/` live there.
13. `Web::LedgerRepo` runs `git pull --rebase` and `git add -A && commit && push` as shell commands. **Every git subprocess scrubs the `GIT_*` environment.** The pre-commit hook runs the test suite inside `git commit`, git exports `GIT_DIR`/`GIT_WORK_TREE` to hook children, and those override `chdir:` — without the scrub, a test that "commits in a tmpdir" commits to this repo (it happened once, and pushed). `GIT_TOKEN` travels as an `http.extraheader` `-c` flag per invocation and is never written to disk. A rejected push raises and leaves the local commit.
14. `B2` is a hand-rolled SigV4 client over `Net::HTTP` (no aws-sdk, for memory). Path-style URLs, header auth for `put`, query auth for `presigned_url` (10 minutes). Keys live under `frijolero/` (the bucket is shared) and contain spaces (`frijolero/accounts/AMEX/AMEX 2508.pdf`), and the canonical URI must encode them as `%20` in both the signature and the emitted URL; `uri_encode` is the single place that does it, and the tests replay two official AWS vectors. `Config.pdf_key` is the one formula for the key.
15. One-time scripts, both idempotent and read-only on their source: `LedgerBuilder` (`script/build_ledger_repo`) turns `~/Documents/Beancount` + `~/.frijolero` into the ledger repo layout (renames `Account_YYMM` → `Account YYMM`, resolves keys case-insensitively, rewrites `include` lines, `detailers/` → `rules/`, drops `config.yaml`, adds the `classify` prompt). `PdfUploader` (`script/upload_pdfs_to_b2`) sends the old PDFs to B2 under the new keys. Both report every file they do not understand as `skip` and exit 1.

**Key files:**
- `lib/frijolero.rb` - main require file
- `lib/frijolero/config.rb` - reads `LEDGER_DIR`, `LEDGER_MAIN_FILE`, `OPENAI_API_KEY`, `OPENAI_POLL_TIMEOUT` and derives every path in the ledger repo. `openai_prompt_spec` delegates to `PromptSpec`
- `lib/frijolero/prompt_spec.rb` - assembles the inline OpenAI request spec from a `config/prompts/<type>/` folder (spec.json + instructions.txt + schema.json)
- `lib/frijolero/account_config.rb` - filename parsing and account lookup. `find_config` is an exact key lookup into `config/accounts.yaml`. `parse_filename` needs a single space before the period
- `lib/frijolero/accounts.rb` - beancount account extraction and search
- `lib/frijolero/pipeline.rb` - per-account-type strategies (summary, detailer toggle, converter dispatch)
- `lib/frijolero/statement.rb` - one PDF's lifecycle: parse filename → check overwrite → upload → extract → save JSON → detail → convert → merge → finalize
- `lib/frijolero/openai_client.rb` - OpenAI client + nested `Transport` + typed exception hierarchy
- `lib/frijolero/openai_error_reporter.rb` - error → `{recoverable, report}` policy table
- `lib/frijolero/converters/{base,amounts,account_targets,beancount,cetes_directo,fintual,plata}.rb` - JSON-to-beancount converters and shared scaffolding
- `lib/frijolero/converters/plata/{entry,corporate_action,positions}.rb` - the Alpaca statement's row stream, its split/spinoff basis allocation, and the commodity accounts it opens and closes
- `lib/frijolero/detailer.rb` + `lib/frijolero/detailer/rules.rb` - JSON enrichment + the shared YAML matching engine
- `lib/frijolero/beancount_detailer.rb` - re-runs detailer rules against a converted `.beancount` (FIXME-only, idempotent)
- `lib/frijolero/beancount_merger.rb` - appends an `include` line to the main ledger file
- `lib/frijolero/beancount/{parser,quoting,header,transaction}.rb` - parses a `.beancount` file into typed blocks, escapes string literals, builds the `DATE FLAG "payee" "narration"` line, and gives a surgically-editable view of a parsed transaction block (used by `BeancountDetailer`)
- `lib/frijolero/ui.rb` - writes plain lines to `UI.sink`
- `lib/frijolero/classifier.rb` - account and period for a PDF (filename shortcut, else one OpenAI call with the `classify` prompt)
- `lib/frijolero/b2.rb` - SigV4 `put` and `presigned_url` over `Net::HTTP`
- `lib/frijolero/ledger_builder.rb`, `lib/frijolero/pdf_uploader.rb` + `script/build_ledger_repo`, `script/upload_pdfs_to_b2` - the one-time migration scripts
- `lib/frijolero/web/app.rb` - the Rack/Sinatra app: collaborators, dashboard, upload/confirm, jobs, PDF redirect
- `lib/frijolero/web/statements.rb` - statement page and `POST .../detail` (reopens `App`)
- `lib/frijolero/web/editors.rb` - rules and accounts editors (reopens `App`)
- `lib/frijolero/web/jobs.rb` - queue, worker thread, `jobs.jsonl`
- `lib/frijolero/web/ledger_repo.rb` - `git pull` / `commit_and_push` with the `GIT_*` scrub
- `lib/frijolero/web/dashboard.rb` - received/missing/pending per account and month
- `lib/frijolero/web/views/*.erb`, `lib/frijolero/web/public/{app.js,style.css}` - browser UI (standalone pages, no layout)
- `lib/frijolero/templates/prompts/{default,plata,classify}/` - version-controlled prompt templates. Copy a folder into a ledger repo's `config/prompts/` to start a new one. `classify` is the classifier's prompt; its account enum is a placeholder that `Classifier` fills at request time
- `config.ru` - Rack entry point
- `config/puma.rb` - Puma server config

**Configuration:** every setting lives in `config/` inside the ledger repo, or in an environment variable. There is no `~/.frijolero/` directory.

- `config/accounts.yaml` - maps an account key to its Beancount account, `openai_prompt_type`, and optional `converter_type`. The key is also the folder name under `accounts/` and the prefix of every file name for that account. An optional `description` names the account for the classifier. `closed: true` hides the account from the dashboard and the classifier (`AccountConfig.active`) while `find_config` keeps resolving it for history.
- `config/rules/{account_key}.yaml` - transaction matching rules per account
- `config/prompts/{type}/` - inline OpenAI extraction prompt per type: `spec.json` (model + `text.format` metadata), `instructions.txt` (system instructions), `schema.json` (strict JSON schema). `Config.openai_prompt_spec(type)` reads the folder and assembles the request body — sent inline on every `/responses` call (no stored `pmpt_...` IDs). The `default` and `plata` prompts are version-controlled at `lib/frijolero/templates/prompts/`. The `plata` prompt (`alpaca_statement_v1`) mirrors the Alpaca statement 1:1 and copies `entry_type` **verbatim** rather than mapping it to an enum — classification belongs in `Converters::Plata` where it is testable, and an unrecognised type must reach the converter so it can emit a visible FIXME instead of vanishing.

| Variable | Purpose |
|---|---|
| `LEDGER_DIR` | Path to the clone of the ledger repo. Required. |
| `LEDGER_MAIN_FILE` | Name of the main Beancount file, relative to `LEDGER_DIR`. Default: `transactions.beancount`. |
| `OPENAI_API_KEY` | Key for the OpenAI extraction calls. Required. |
| `OPENAI_POLL_TIMEOUT` | Seconds to poll a background extraction before it times out. Default: 900. |
| `APP_PASSWORD` | The one password for HTTP basic auth. Required. |
| `PUMA_THREADS` | Thread pool size for the Puma server. |
| `B2_ENDPOINT`, `B2_BUCKET`, `B2_KEY_ID`, `B2_KEY` | The S3-compatible endpoint, bucket and key pair of Backblaze B2, where the PDFs live. Required. |
| `GIT_TOKEN` | GitHub fine-grained token with push access to the ledger repo. Sent as an HTTP header per git call; never written to disk. |

**Tests:** Minitest, run with `bundle exec rake test`. Fixtures in `test/fixtures/`. `with_ledger_dir` is the test helper that points `LEDGER_DIR` at a temp dir. Web tests use `rack-test` against `Web::App` directly and swap the class-level collaborators for fakes; `test/web_app_test.rb` alone loads `config.ru` to cover the auth wiring. Any test that shells out to git must scrub `GIT_*` from the subprocess environment (see item 13) and should be run once as `GIT_DIR=$(pwd)/.git GIT_WORK_TREE=$(pwd) bundle exec rake test` to prove it cannot touch this repo.

**Transaction JSON format:**
```json
{
  "transactions": [
    {
      "date": "2024-01-15",
      "description": "AMAZON WEB SERVICES",
      "amount": -50.00,
      "currency": "MXN",
      "payee": "optional",
      "narration": "optional",
      "expense_account": "optional"
    }
  ]
}
```

**Detailer YAML structure:**
```yaml
start_with:
  # Simple rule — matches description prefix
  PATTERN:
    payee: "Name"
    narration: "Description"
    account: "Expenses:Category"

  # Conditional rule — also requires exact amount match
  PATTERN:
    when:
      amount: -149
    payee: "Name"
    account: "Expenses:Category"

  # Array of rules — first matching `when` wins, entry without `when` is fallback
  PATTERN:
    - when:
        amount: -15000
      payee: "Landlord"
      account: "Expenses:Rent"
    - payee: "Transfer"
      account: "Expenses:Misc"

include:
  PATTERN:
    # same fields and formats as start_with
```
