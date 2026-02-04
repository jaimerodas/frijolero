# frozen_string_literal: true

require 'json'
require 'date'
require 'optparse'
require_relative 'lib/account_config'

module JsonToBeancount
  DEFAULT_EXPENSE_ACCOUNT = "Expenses:FIXME"

  def self.convert(
    input:,
    account:,
    output: nil,
    expense_account: DEFAULT_EXPENSE_ACCOUNT
  )
    raise ArgumentError, "input file required" unless input
    raise ArgumentError, "account required" unless account

    output ||= File.join(File.dirname(input), '..', 'beancount', File.basename(input, ".json") + ".beancount")

    json = JSON.parse(File.read(input))

    File.open(output, "w") do |out|
      json.fetch("transactions", []).each do |tx|
        date      = Date.parse(tx.fetch("date")).strftime("%Y-%m-%d")
        description = (tx["description"] || "").gsub(/\s+/, " ").strip
        narration = tx["narration"]
        payee = tx["payee"]
        amount    = tx.fetch("amount").to_f
        currency  = tx["currency"] || "MXN"
        set_expense_account = tx["expense_account"] || expense_account

        if !narration
          narration = description
          description = false
        end

        if payee
          out.puts %{#{date} * "#{payee}" "#{narration}"}
        else
          out.puts %{#{date} * "#{narration}"}
        end

        if description
          out.puts %{  source_desc: "#{description}"}
        end

        out.puts "  #{account}  #{format('%.2f', amount)} #{currency}"
        out.puts "  #{set_expense_account}"
        out.puts
      end
    end

    output
  end
end

# -------------------------
# CLI entry point
# -------------------------
if $PROGRAM_NAME == __FILE__
  options = {}

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: json_to_beancount.rb FILE.json [-a ACCOUNT] [-o OUTPUT.beancount]"

    opts.on("-a", "--account ACCOUNT", "Primary account (auto-detected from filename if omitted)") do |v|
      options[:account] = v
    end

    opts.on("-o", "--output FILE", "Output Beancount file (default: data/output/beancount/<basename>.beancount)") do |v|
      options[:output] = v
    end

    opts.on("-e", "--expense ACCOUNT", "Expense account (default: Expenses:FIXME)") do |v|
      options[:expense_account] = v
    end

    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit
    end
  end

  parser.parse!
  input = ARGV[0]

  unless input
    warn "Error: Input file required"
    warn parser
    exit 1
  end

  options[:input] = input

  unless options[:account]
    account = AccountConfig.beancount_account_for_file(input)
    if account
      puts "Auto-detected account: #{account}"
      options[:account] = account
    else
      warn "Error: Could not auto-detect account for '#{File.basename(input)}'"
      warn "Available accounts: #{AccountConfig.available_accounts.join(', ')}"
      warn "Use -a to specify an account explicitly"
      exit 1
    end
  end

  JsonToBeancount.convert(**options)
end
