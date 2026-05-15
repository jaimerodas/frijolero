# Frijolero

CLI tool for processing PDF bank/credit card statements and converting them to Beancount accounting format.

## Features

- Process PDF statements through OpenAI extraction
- Enrich transactions with custom matching rules
- Convert to Beancount format
- Merge into main ledger
- Export to CSV

## Installation

```bash
gem install frijolero
```

Or add to your Gemfile:

```ruby
gem "frijolero"
```

## Setup

Initialize configuration:

```bash
frijolero init
```

This creates `~/.frijolero/` with:
- `config.yaml` - API keys and paths
- `accounts.yaml` - Account name to beancount account mapping
- `detailers/` - Transaction matching rules

Edit these files to configure your accounts and rules.

## Configuration

### config.yaml

```yaml
openai_api_key: sk-xxx

openai_prompts:
  default: pmpt_xxx
  bbva: pmpt_yyy

paths:
  beancount_main: ~/finances/main.beancount
  statements_input: ~/Downloads/statements
```

Processed statement artifacts (PDFs, JSON, beancount files) are organized
under the directory containing `beancount_main`, one folder per account:

```
~/finances/
  main.beancount
  Amex/
    Amex_2501.beancount   # included directly by main.beancount
    pdf/Amex_2501.pdf
    json/Amex_2501.json
```

### accounts.yaml

Maps filename prefixes to beancount accounts. The **keys are the canonical
capitalization** used for file and directory names — drop `AMEX 2501.pdf`
in your inbox and it still lands as `Amex/Amex_2501.beancount`, matching
the `Amex:` key below. The lookup is case-insensitive and treats spaces
and underscores as equivalent.

```yaml
Amex:
  beancount_account: "Liabilities:Amex"
  openai_prompt_type: default

BBVA:
  beancount_account: "Assets:BBVA"
  openai_prompt_type: bbva
```

### Detailer rules

Create YAML files in `~/.frijolero/detailers/` (e.g., `amex.yaml`):

```yaml
start_with:
  AMAZON WEB SERVICES:
    payee: Amazon
    narration: AWS
    account: Expenses:Subscriptions

  STARBUCKS:
    payee: Starbucks
    account: Expenses:Food:Coffee

include:
  GROCERY:
    account: Expenses:Food:Groceries
```

Rules support an optional `when` clause for additional conditions (currently exact `amount` match):

```yaml
start_with:
  # Only match when amount is exactly -149
  NETFLIX:
    when:
      amount: -149
    payee: Netflix
    account: Expenses:Subscriptions

  # Use an array to classify the same prefix by amount.
  # First matching entry wins; entry without `when` is a fallback.
  TRANSFERENCIA:
    - when:
        amount: -15000
      payee: Landlord
      narration: Rent
      account: Expenses:Housing:Rent
    - when:
        amount: -500
      payee: Gym
      account: Expenses:Health
    - payee: Transfer
      account: Expenses:Misc
```

## Usage

### Process PDF statements

```bash
# Process all PDFs in input directory
frijolero process

# Preview without making changes
frijolero process --dry-run
```

Filename format: `Account Name YYMM.pdf` (e.g., `Amex 2501.pdf`)

### Enrich transactions

```bash
# Auto-detect config from filename
frijolero detail Amex_2501.json

# Specify config explicitly
frijolero detail transactions.json -c ~/.frijolero/detailers/amex.yaml
```

### Convert to Beancount

```bash
# Auto-detect account from filename
frijolero convert Amex_2501.json

# Specify account and output
frijolero convert input.json -a "Liabilities:Amex" -o output.beancount
```

### Merge into main ledger

```bash
# Merge files
frijolero merge file.beancount

# Preview without merging
frijolero merge file1.beancount file2.beancount --dry-run
```

### Export to CSV

```bash
frijolero csv transactions.json
frijolero csv transactions.json -o output.csv
```

### Migrate from the old layout

Earlier versions of frijolero stored artifacts under
`{statements_output}/{json,beancount,processed}` and copied .beancount files
into `{main_dir}/transactions/{account}/`. The current layout co-locates
everything per account under the main ledger's directory.

```bash
# Preview the migration plan (touches nothing)
frijolero migrate --old-output-dir ~/finances/processed

# Copy files into the new layout, verify, then prompt before deleting originals
frijolero migrate --apply --old-output-dir ~/finances/processed
```

The migrator copies first, verifies every file with SHA-256, rewrites
`main.beancount` includes (saving a timestamped `.bak`), and only deletes
the originals if you explicitly type `yes` at the final prompt. Pass
`--no-prompt` for non-interactive runs (originals are retained).

File and directory names are normalized to match the canonical capitalization
from `accounts.yaml`: `transactions/Cetes/CETES_2604.beancount` becomes
`Cetes/Cetes_2604.beancount`. Files whose prefix isn't found in `accounts.yaml`
are migrated with their original capitalization and surfaced in an
"Unknown accounts" section of the plan output.

## Transaction JSON Format

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

## License

MIT
