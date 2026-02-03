# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Ruby scripts for processing bank/credit card transaction data and converting to Beancount accounting format.

## Commits

- Escribe los mensajes de commit en español
- Mantenlos simples y concisos

## Commands

```bash
# Process all PDF statements in input directory
ruby process_statements.rb
ruby process_statements.rb --dry-run

# Enrich transactions with a specific config
ruby generic_detailer.rb transactions.json config/account.yaml

# Convert JSON transactions to Beancount format
ruby json_to_beancount.rb -i input.json -a "Liabilities:Amex"

# Convert JSON transactions to CSV
ruby json_to_csv.rb -i input.json -o output.csv

# Merge beancount files into main ledger
ruby merge_beancount.rb file.beancount -o main.beancount
ruby merge_beancount.rb file1.beancount file2.beancount --dry-run
```

## Architecture

**Processing pipeline:**
1. `process_statements.rb` orchestrates the full workflow: PDF → OpenAI extraction → detailer enrichment → beancount
2. `generic_detailer.rb` enriches transactions using YAML config files in `config/`
3. `json_to_beancount.rb` converts enriched JSON to Beancount format
4. `merge_beancount.rb` appends processed beancount files to the main ledger

**Configuration files (in `config/`):**
- `accounts.yaml` - maps filename prefixes to beancount accounts
- `{account}.yaml` - detailer rules for each account (e.g., `amex.yaml`, `bbva.yaml`)

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
