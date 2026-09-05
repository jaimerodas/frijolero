# Frijolero

Frijolero is a web app for personal accounting. You upload a PDF bank or
credit card statement. OpenAI extracts the transactions. Rules enrich each
transaction with a payee and an account. The app writes the result to a
Beancount file, and that file joins a ledger that lives in a git repo.

Version 2 of Frijolero replaced the command-line tool with this web app.

## Status

Frijolero is under construction. Two parts exist today:

- The domain code (converters, detailer, and Beancount parser) is unchanged from the CLI.
- `Config` reads its settings from environment variables.
- A Rack app skeleton, with HTTP basic auth and a `/up` health check route that answers without a password.

These parts are still in progress:

- The upload flow for a PDF statement
- Automatic account classification
- A dashboard of received and missing statements
- Backups to Backblaze B2
- Git sync for the ledger repo
- A web editor for the rules files

See `docs/webapp-plan.md` for the full plan.

## Environment variables

| Variable | Purpose |
|---|---|
| `LEDGER_DIR` | Path to the clone of the ledger repo. Required. |
| `LEDGER_MAIN_FILE` | Name of the main Beancount file, relative to `LEDGER_DIR`. Default: `transactions.beancount`. |
| `OPENAI_API_KEY` | Key for the OpenAI extraction calls. Required. |
| `APP_PASSWORD` | The one password for HTTP basic auth, on every route except `/up`. Required. |
| `B2_ENDPOINT`, `B2_BUCKET`, `B2_KEY_ID`, `B2_KEY` | Backblaze B2 credentials for statement PDFs. Not read yet. |
| `GIT_TOKEN` | Push access to the ledger repo over HTTPS. Not read yet. |
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

The `default` and `plata` folders ship as templates at
`lib/frijolero/templates/prompts/`. Copy one to start a new prompt type.

## Run locally

Install the dependencies, then start the app:

```bash
bundle install
LEDGER_DIR=~/Developer/beancount-ledger APP_PASSWORD=change-me OPENAI_API_KEY=sk-... \
  bundle exec puma -C config/puma.rb config.ru
```

Open http://localhost:9292. The `/up` route answers without a password.

## Development

```bash
bundle exec rake test
bundle exec rubocop
```

The Ruby version comes from `.ruby-version` (4.0.6).

## License

MIT
