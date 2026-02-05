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
  statements_output: ~/finances/processed
```

### accounts.yaml

Maps filename prefixes to beancount accounts:

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
