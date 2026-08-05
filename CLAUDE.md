# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Ruby gem (`frijolero`) for processing bank/credit card transaction data and converting to Beancount accounting format. Single CLI binary with subcommands.

## Commits

- Escribe los mensajes de commit en español
- Mantenlos simples y concisos

## Commands

```bash
# Run tests + rubocop (also wired into script/test and script/test_fast)
bundle exec rake test
bundle exec rubocop

# CLI usage
bundle exec frijolero --help
bundle exec frijolero process [--dry-run] [--auto-accept-prompts]
bundle exec frijolero detail Amex_2501.json
bundle exec frijolero detail transactions.json -c config.yaml
bundle exec frijolero detail Amex_2501.beancount             # re-run rules on an already-converted ledger
bundle exec frijolero detail Amex_2501.beancount --dry-run
bundle exec frijolero convert Amex_2501.json
bundle exec frijolero convert input.json -a "Liabilities:Amex" -o output.beancount
bundle exec frijolero csv input.json -o output.csv
bundle exec frijolero merge file.beancount -o main.beancount
bundle exec frijolero review Amex_2501.json
bundle exec frijolero review input.json -a "Liabilities:Amex" -p 3000
bundle exec frijolero migrate [--apply] [--no-prompt] [--old-output-dir PATH]
bundle exec frijolero init

# Build gem
gem build frijolero.gemspec
```

## Architecture

**Gem structure:** All code lives under `lib/frijolero/` within the `Frijolero` module.

**File layout:** Processed artifacts are organized per-account under the directory containing `main.beancount`:

```
ledger_dir/                     # = File.dirname(beancount_main_file) = statements_output_dir
  main.beancount                # includes "Amex/Amex_2501.beancount" directly
  accounts.beancount
  Amex/
    Amex_2501.beancount         # canonical, included by main
    pdf/Amex_2501.pdf
    json/Amex_2501.json
```

The directory containing `main.beancount` IS the implicit `statements_output_dir` (no separate `paths.statements_output` config key). `accounts.yaml` keys are the source of truth for an account's canonical capitalization — both the processing pipeline and the migrator normalize file/dir names to match.

**Processing pipeline:**
1. `StatementProcessor` is the batch orchestrator: enumerates PDFs in the input dir and aborts on `OpenAIClient::InsufficientQuotaError` or `AuthenticationError`. Per-PDF work is delegated to `Statement`.
2. `Statement` owns one PDF's lifecycle (parse filename → check overwrite → upload → extract → save JSON → detail → convert → merge → finalize). Each step is a small private method.
3. `OpenAIErrorReporter` is the error-handling policy table — maps each `OpenAIClient::Error` subclass to `{recoverable:, report:}` and is invoked from `Statement#run_pipeline`'s single rescue clause.
4. `Pipeline.for(account_config)` returns a strategy (`Pipeline::Default`, `CetesDirecto`, `Fintual`, or `Plata`) that knows how to summarize the extracted data, whether to run the detailer, and which underlying converter to call. Adding a new bank statement type means adding one strategy class plus one converter — no edits to `Statement` or `StatementProcessor`.
5. `Detailer` enriches transactions using YAML rules (only for `Default` pipeline). The matching itself lives in `Detailer::Rules` — a pure engine over the YAML that knows nothing about JSON — so `BeancountDetailer` can reuse it to re-run the rules against an already-converted `.beancount` file. That closes the loop where you notice a missing rule while cleaning up `Expenses:FIXME` rows in fava: add the rule, re-run `detail` on the `.beancount`, no need to go back to the JSON and redo the conversion and merge. `BeancountDetailer` only ever rewrites transactions still posting to `Expenses:FIXME`, which both protects hand edits and makes the run idempotent. It edits surgically via `Beancount::Transaction` (header line + the one FIXME posting), so hand-added metadata, comments and extra postings survive verbatim. Known limitation, inherited from `Beancount::Parser::TRANSACTION_RE` (which matches only the `*` flag): a transaction flagged `!` is invisible to the detailer — it is neither detailed nor counted in `remaining`, so the summary under-reports if you flag a row `!` in fava while leaving it on `Expenses:FIXME`.
6. `Converters::Beancount` / `Converters::CetesDirecto` / `Converters::Fintual` / `Converters::Plata` convert enriched JSON to Beancount format (invoked by the pipeline strategy). All four inherit from `Converters::Base` (output path resolution, `convert`/`run_to(io)` template). `Converters::AccountTargets` is the value object that bundles `counterpart`/`interest`/`tax`/`dividend`/`gains`/`fees`/`withholding`/`opening` so converters take three keyword args instead of ten. `Converters::Amounts` is the shared number mixin — all parsing goes through `BigDecimal`, because Float turns an exact reconciliation into a residue like `-5.55e-17` that renders in scientific notation and that Beancount's parser rejects.

**The Plata converter reads Alpaca brokerage statements, not the advisor's.** `Plata Investments` is a US brokerage account custodied at Alpaca and held through a Mexican advisor. The advisor also issues its own Spanish summary statement; that document is incomplete (dividends reported net of withholding, no transfer detail, corporate actions invisible) and the converter was rewritten in 0.10.0 to read the Alpaca statement instead. Do not point this pipeline back at the advisor PDF. The Alpaca statement reconciles exactly — every Cash Summary line is reproducible from the four detail tables to the cent — and that property is what the converter and its tests are built on.

Its structure: `Plata::Entry` flattens the statement's four detail tables (Transaction, Income, Fees, Deposit & Withdrawals) into one date-ordered stream. The sort is *stable on printed position*, which matters twice — a dividend booked, reversed and rebooked on one date must keep that order, and the rows of one corporate action must stay adjacent so the converter can group them. `Plata::CorporateAction` handles `Stock Split` and `Stock SpinOff`: they conserve cost basis, but Alpaca's printed per-share price on the new side is rounded (NFLX 5 @ 480.46 = 2402.30 becomes 50 @ 48.05, which multiplies back to 2402.50), so the *removed* total is authoritative and additions are allocated against it, the largest absorbing the residue. The sign of `quantity` — never the description text — separates removals from additions, because a spinoff's target row carries neither the word ADD nor REMOVE.

Three Plata behaviours are deliberate and easy to "fix" wrongly: `High-Yield Cash Sweep` rows are skipped (they move cash between the brokerage and the FDIC partner banks, are absent from the Cash Summary, and emitting them double-counts); `Journal Entry(Cash)` rows are booked to `Expenses:FIXME` flagged `*` so `frijolero detail <file>.beancount` can resolve them from a rules file, because their counterpart is genuinely not in the statement; and a closing `balance` assertion is emitted for cash *and every holding*, which is what replaced the old `UnitReconciler` share-count guesswork. A position exited mid-month drops out of the Holdings table, so it cannot be asserted to zero — that is the one gap the assertions do not cover.

**Commodity accounts are opened and closed by the converter, not by hand.** `Plata::Positions` recovers each symbol's opening count as `closing - moved` — the statement never states it, but it reports the closing count and every movement that produced it. A symbol whose opening count is zero gets an `open ... "FIFO"` dated at period start; one whose closing count is zero gets a `close` dated with the balance assertions; a symbol bought and sold inside one month gets both. A symbol is only considered if it has share movements this period, which is what stops a dividend for a position exited months ago (it carries no quantity) from reading as an exit. A split must not trip this: it removes the whole position and adds it back under the same symbol, so opening and closing are both non-zero.

Consequences worth knowing: **only commodity accounts are managed this way** — Cash, income, expense and equity accounts outlive any one statement and stay in the ledger's `account_opens` file — and declaring a Plata commodity account in both places is a duplicate-open error. The real limitation is re-entry: beancount refuses to reopen a closed account, so a position exited in one month and repurchased in a later one produces a colliding `close`/`open` pair across two files. It fails loudly at `bean-check` (`Account ... is already open` plus `Posting to inactive account`) and the fix is to delete the earlier `close` and the later `open`. No converter can detect it, because a converter only ever sees one month.

**Beancount booking methods:** the investment converters emit `{}` reductions on sales, which are ambiguous under Beancount's default STRICT booking once a commodity has more than one lot. Commodity accounts must therefore be opened with FIFO — `2025-01-01 open Assets:Investments:Plata:AAPL AAPL "FIFO"`. `"AVERAGE"` is not a substitute: real Beancount rejects it outright (`AVERAGE method is not supported`) and rustledger silently zeroes the position on any reduction. Note that a `booking: "AVERAGE"` line indented under an `open` is *metadata*, silently ignored — the method belongs on the open line itself.
7. `BeancountMerger` appends an `include "{account}/{file}.beancount"` line to the main ledger pointing at the canonical converter output — no file copy.
8. `TransactionSplitter` extracts inline transactions for one account into per-month files at `{ledger_dir}/{account}/{account}_YYMM.beancount`; uses `Beancount::Parser` (parses a `.beancount` file into typed blocks) and `Beancount::MainFileWriter` (rewrites the main file with `include` statements + collapses blank-line runs).
9. `CsvConverter` exports transactions to CSV.
10. `OpenAIClient` handles PDF upload/extraction via OpenAI API. HTTP transport, auth, and error mapping live in nested `OpenAIClient::Transport`; the outer class is a thin domain layer over it. Errors surface as typed exceptions: `AuthenticationError`, `InsufficientQuotaError`, `RateLimitError`, `APIError`, `NetworkError`.
11. `UI` wraps `cli-ui` gem for terminal output (frames, spinners, prompts).
12. `Accounts` parses beancount file for account names (autocomplete support).
13. `Web::App` Sinatra app for reviewing/editing transactions in browser.
14. `LayoutMigrator` (one-shot) migrates installations from the legacy `output/{json,beancount,processed}` + `ledger/transactions/{account}/` layout to the current per-account layout. `PlanBuilder` walks the legacy tree and produces an immutable `Plan` (copies, redundants, conflicts, unhandled, warnings). `PlanFormatter` renders the plan and summary. The migrator copies → SHA-256-verifies → rewrites `main.beancount` with a timestamped backup → prompts → deletes; originals are never lost without explicit `yes`. `FileCompare` provides the shared `bytes_equal?` helper.

**Key files:**
- `lib/frijolero.rb` - main require file
- `lib/frijolero/cli.rb` - thin subcommand dispatcher (hash registry of `COMMANDS`)
- `lib/frijolero/cli/{init,process,detail,convert,merge,csv,review,rename,split,migrate}.rb` - one class per subcommand, each implementing `.call(args)`
- `lib/frijolero/cli/helpers.rb` - shared mixin for command classes (`check_config!`, `help_option`, etc.)
- `lib/frijolero/ui.rb` - reusable terminal UI wrapper (CLI::UI)
- `lib/frijolero/config.rb` - loads config from `~/.frijolero/`; `statements_output_dir` derives from `File.dirname(beancount_main_file)`; `openai_prompt_spec` delegates to `PromptSpec`
- `lib/frijolero/prompt_spec.rb` - assembles the inline OpenAI request spec from a `prompts/<type>/` folder (spec.json + instructions.txt + schema.json)
- `lib/frijolero/account_config.rb` - filename parsing and account lookup; `canonical_account_name`/`canonical_prefix` resolve a parsed prefix to its `accounts.yaml` key
- `lib/frijolero/accounts.rb` - beancount account extraction and search
- `lib/frijolero/pipeline.rb` - per-account-type strategies (summary, detailer toggle, converter dispatch)
- `lib/frijolero/statement_processor.rb` + `lib/frijolero/statement.rb` - batch loop + per-PDF orchestrator (Statement canonicalizes `@account_name` from `accounts.yaml` after `find_config`)
- `lib/frijolero/openai_client.rb` - OpenAI client + nested `Transport` + typed exception hierarchy
- `lib/frijolero/openai_error_reporter.rb` - error → `{recoverable, report}` policy table
- `lib/frijolero/converters/{base,amounts,account_targets,beancount,cetes_directo,fintual,plata}.rb` - JSON-to-beancount converters and shared scaffolding
- `lib/frijolero/converters/plata/{entry,corporate_action,positions}.rb` - the Alpaca statement's row stream, its split/spinoff basis allocation, and the commodity accounts it opens and closes
- `lib/frijolero/detailer.rb` + `lib/frijolero/detailer/rules.rb` - JSON enrichment + the shared YAML matching engine
- `lib/frijolero/beancount_detailer.rb` - re-runs detailer rules against a converted `.beancount` (FIXME-only, idempotent)
- `lib/frijolero/beancount/{parser,main_file_writer}.rb` - parse/rewrite `.beancount` files (used by TransactionSplitter)
- `lib/frijolero/beancount/{quoting,header,transaction}.rb` - string-literal escaping, the `DATE FLAG "payee" "narration"` line, and a surgically-editable view of a parsed transaction block (used by BeancountDetailer)
- `lib/frijolero/json_statement_summary.rb` - describes the contents of a transactions JSON file (used in overwrite prompts)
- `lib/frijolero/layout_migrator.rb` + `lib/frijolero/layout_migrator/{plan,plan_builder,plan_formatter,file_compare}.rb` - legacy-to-current layout migrator (copy/verify/rewrite/prompt/delete) and its helper classes
- `lib/frijolero/web/app.rb` - Sinatra web UI (lazy-loaded by `review` command)
- `bin/frijolero` - CLI entry point

**Configuration (in `~/.frijolero/`):**
- `config.yaml` - API key and `paths` (`beancount_main`, `beancount_accounts`, `statements_input`). There is no `statements_output` key — the output dir is the directory containing `beancount_main`. (No longer holds OpenAI prompt IDs — those moved to `prompts/`.)
- `accounts.yaml` - maps filename prefixes to beancount accounts; keys are the canonical capitalization used in file/dir names. `openai_prompt_type` selects which `prompts/<type>/` folder to use.
- `detailers/{account}.yaml` - transaction matching rules per account
- `prompts/{type}/` - inline OpenAI extraction prompt per type: `spec.json` (model + `text.format` metadata), `instructions.txt` (system instructions), `schema.json` (strict JSON schema). `Config.openai_prompt_spec(type)` reads the folder and assembles the request body — sent inline on every `/responses` call (no stored `pmpt_...` IDs). The `default` and `plata` prompts are version-controlled at `lib/frijolero/templates/prompts/`, which `frijolero init` copies into `~/.frijolero/`; edit them there and copy across, not only in the home directory. The `plata` prompt (`alpaca_statement_v1`) mirrors the Alpaca statement 1:1 and copies `entry_type` **verbatim** rather than mapping it to an enum — classification belongs in `Converters::Plata` where it is testable, and an unrecognised type must reach the converter so it can emit a visible FIXME instead of vanishing.

**Tests:** Minitest, run with `bundle exec rake test`. Fixtures in `test/fixtures/`.

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
