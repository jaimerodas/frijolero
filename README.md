# Frijolero

Frijolero is a web app for personal accounting. You upload a PDF bank or
credit card statement. OpenAI extracts the transactions. Rules enrich each
transaction with a payee and an account. The app writes the result to a
Beancount file, and that file joins a ledger that lives in a git repo.

Version 2 of Frijolero replaced the command-line tool with this web app.

## Status

All the parts of version 1 of the plan exist in the code. The first deploy
is still pending.

- Upload a PDF. The app classifies it (account and period) and asks you to confirm.
- A background job runs the pipeline: pull the ledger, save the PDF to B2, extract with OpenAI, validate, detail, convert, merge, commit, push.
- A dashboard shows, per account, if the previous month and the current month are received, missing, pending, or failed.
- A statement page shows the transactions, the FIXME count, the Beancount preview, and a signed PDF download.
- Editors for the rules files and for `accounts.yaml`, with validation. "Make a rule" prefills a rule from a FIXME row.
- Two one-time scripts build the ledger repo from the old layout and upload the old PDFs to B2.

See `docs/webapp-plan.md` for the plan and the decisions behind it.

## Environment variables

| Variable | Purpose |
|---|---|
| `LEDGER_DIR` | Path to the clone of the ledger repo. Required. |
| `LEDGER_MAIN_FILE` | Name of the main Beancount file, relative to `LEDGER_DIR`. Default: `transactions.beancount`. |
| `OPENAI_API_KEY` | Key for the OpenAI extraction calls. Required. |
| `APP_PASSWORD` | The one password for HTTP basic auth, on every route except `/up`. Required. |
| `B2_ENDPOINT`, `B2_BUCKET`, `B2_KEY_ID`, `B2_KEY` | The S3-compatible endpoint, bucket, and key pair of Backblaze B2. PDFs live there. Required. |
| `GIT_TOKEN` | A GitHub fine-grained token with push access to the ledger repo. The app sends it in an HTTP header on each git call and never writes it to disk. Optional for a local path remote. |
| `PUMA_THREADS` | Thread pool size for the Puma server. |
| `OPENAI_POLL_TIMEOUT` | Seconds to poll a background extraction before it times out. Default: 900. |

## The ledger repo

`LEDGER_DIR` points at a git repo with this layout:

```
ledger/
  transactions.beancount        # LEDGER_MAIN_FILE, includes the account files
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
      Amex 2501.beancount
      Amex 2501.json
```

A statement file name has the account key, one space, and the closing
period as `YYMM`. The period is the month the statement closes, not the
month you upload it.

## Configuration

### config/accounts.yaml

This file maps an account key to a Beancount account. The key is also the
folder name under `accounts/` and the prefix of every file name for that
account. `description` gives the app a hint for classification.

```yaml
Amex:
  beancount_account: "Liabilities:Amex"
  openai_prompt_type: default
  description: "Amex credit card (tarjeta de crédito), MXN"

BBVA:
  beancount_account: "Assets:BBVA"
  openai_prompt_type: bbva
  description: "BBVA checking account (cuenta de débito), MXN"
```

### config/rules/\<Account\>.yaml

Each account has one rules file, named after its account key
(`config/rules/Amex.yaml` for the `Amex` account). Each rule matches a
transaction description and sets a `payee`, a `narration`, and an
`account`.

```yaml
start_with:
  # Simple rule: matches a description that starts with the pattern.
  AMAZON WEB SERVICES:
    payee: Amazon
    narration: AWS
    account: Expenses:Subscriptions

  # `when` adds a condition. This rule also needs an exact amount match.
  NETFLIX:
    when:
      amount: -149
    payee: Netflix
    account: Expenses:Subscriptions

  # A list tries each `when` in order. An entry with no `when` is the fallback.
  TRANSFERENCIA:
    - when:
        amount: -15000
      payee: Landlord
      narration: Rent
      account: Expenses:Housing:Rent
    - payee: Transfer
      account: Expenses:Misc

include:
  # `include` matches a description that contains the pattern, anywhere in it.
  GROCERY:
    account: Expenses:Food:Groceries
```

### config/prompts/\<type\>/

Each `openai_prompt_type` in `accounts.yaml` points at a folder here. The
folder holds three files:

- `spec.json` sets the model and the output format.
- `instructions.txt` holds the system prompt.
- `schema.json` gives the strict JSON schema for the extracted transactions.

The `default`, `plata`, and `classify` folders ship as templates at
`lib/frijolero/templates/prompts/`. Copy one to start a new prompt type.
`classify` is the prompt that reads the account and the period of an uploaded
PDF; the app fills its account list from `accounts.yaml` on each call.

## Run locally

Install the dependencies, then start the app:

```bash
bundle install
LEDGER_DIR=~/Developer/beancount-ledger APP_PASSWORD=change-me OPENAI_API_KEY=sk-... \
  bundle exec puma -C config/puma.rb config.ru
```

Open http://localhost:9292. The `/up` route answers without a password.

## Deploy

The app runs on the droplet with Kamal 2. `config/deploy.yml` holds the
server, the hostname, the volume `/data`, and the memory cap. `.kamal/secrets`
reads each secret from your shell, so export them before you deploy:

```bash
export KAMAL_REGISTRY_PASSWORD=... OPENAI_API_KEY=... APP_PASSWORD=... \
       B2_KEY_ID=... B2_KEY=... GIT_TOKEN=...
kamal setup      # first time
kamal deploy     # after that
```

Before the first deploy, set `B2_ENDPOINT` and `B2_BUCKET` in
`config/deploy.yml`, and clone the ledger repo into the volume at
`/data/ledger` on the server.

To build and run the image on your machine:

```bash
docker build -t frijolero .
docker run --rm -p 9292:9292 -e APP_PASSWORD=x -e LEDGER_DIR=/data/ledger frijolero
```

## One-time migration

Two scripts move an installation from the old layout (`~/Documents/Beancount`
and `~/.frijolero`) to the new one. Both read the old layout and never change it.

```bash
script/build_ledger_repo                    # builds ~/Developer/beancount-ledger
script/upload_pdfs_to_b2 --dry-run          # shows which PDF goes to which key
B2_ENDPOINT=... B2_BUCKET=... B2_KEY_ID=... B2_KEY=... script/upload_pdfs_to_b2
```

Each script prints a `skip` line for every file it does not understand and
exits with 1 in that case, so read the output before you delete anything.

## Development

```bash
bundle exec rake test
bundle exec rubocop
```

The Ruby version comes from `.ruby-version` (4.0.6).

## License

MIT
