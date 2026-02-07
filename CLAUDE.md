# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Ruby gem (`frijolero`) for processing bank/credit card transaction data and converting to Beancount accounting format. Single CLI binary with subcommands.

## Commits

- Escribe los mensajes de commit en español
- Mantenlos simples y concisos

## Commands

```bash
# Run tests
bundle exec rake test

# CLI usage
bundle exec frijolero --help
bundle exec frijolero process [--dry-run] [--auto-accept-prompts]
bundle exec frijolero detail Amex_2501.json
bundle exec frijolero detail transactions.json -c config.yaml
bundle exec frijolero convert Amex_2501.json
bundle exec frijolero convert input.json -a "Liabilities:Amex" -o output.beancount
bundle exec frijolero csv input.json -o output.csv
bundle exec frijolero merge file.beancount -o main.beancount
bundle exec frijolero review Amex_2501.json
bundle exec frijolero review input.json -a "Liabilities:Amex" -p 3000
bundle exec frijolero init

# Build gem
gem build frijolero.gemspec
```

## Architecture

**Gem structure:** All code lives under `lib/frijolero/` within the `Frijolero` module.

**Processing pipeline:**
1. `StatementProcessor` orchestrates the full workflow: PDF → OpenAI extraction → detailer enrichment → beancount
2. `Detailer` enriches transactions using YAML rules
3. `BeancountConverter` converts enriched JSON to Beancount format
4. `BeancountMerger` appends processed beancount files to the main ledger
5. `CsvConverter` exports transactions to CSV
6. `OpenAIClient` handles PDF upload/extraction via OpenAI API
7. `UI` wraps `cli-ui` gem for terminal output (frames, spinners, prompts)
8. `Accounts` parses beancount file for account names (autocomplete support)
9. `Web::App` Sinatra app for reviewing/editing transactions in browser

**Key files:**
- `lib/frijolero.rb` - main require file
- `lib/frijolero/cli.rb` - subcommand routing
- `lib/frijolero/ui.rb` - reusable terminal UI wrapper (CLI::UI)
- `lib/frijolero/config.rb` - loads config from `~/.frijolero/`
- `lib/frijolero/account_config.rb` - filename parsing and account lookup
- `lib/frijolero/accounts.rb` - beancount account extraction and search
- `lib/frijolero/web/app.rb` - Sinatra web UI (lazy-loaded by `review` command)
- `bin/frijolero` - CLI entry point

**Configuration (in `~/.frijolero/`):**
- `config.yaml` - API keys, paths (incl. `beancount_accounts`), OpenAI prompts
- `accounts.yaml` - maps filename prefixes to beancount accounts
- `detailers/{account}.yaml` - transaction matching rules per account

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
  PATTERN:
    payee: "Name"
    narration: "Description"
    account: "Expenses:Category"
include:
  PATTERN:
    # same fields
```
