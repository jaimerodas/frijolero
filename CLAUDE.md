# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Ruby scripts for processing bank/credit card transaction data and converting to Beancount accounting format.

## Commands

```bash
# Enrich AMEX transactions with payee/category info from amex.yaml
ruby amex_detailer.rb transactions.json

# Enrich BBVA transactions (rules hardcoded in class)
ruby bbva_detailer.rb transactions.json

# Convert JSON transactions to Beancount format
ruby json_to_beancount.rb -i input.json -a "Liabilities:Amex"
ruby json_to_beancount.rb -i input.json -a "Assets:BBVA" -e "Expenses:Other"

# Convert JSON transactions to CSV
ruby json_to_csv.rb -i input.json -o output.csv
```

## Architecture

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

**Processing pipeline:**
1. Detailers (`*_detailer.rb`) read JSON, enrich transactions with payee/narration/expense_account based on description matching, write back to same file
2. `json_to_beancount.rb` converts enriched JSON to Beancount format (outputs to `../beancount/` by default)
3. `json_to_csv.rb` converts JSON to simple CSV (date, description, amount)

**Class hierarchy:**
- `BaseDetailer` - abstract base with load/process/write workflow
- `AmexDetailer` - uses `amex.yaml` for matching rules (start_with/include patterns)
- `BbvaDetailer` - hardcoded matching rules for BBVA transactions

**amex.yaml structure:**
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
