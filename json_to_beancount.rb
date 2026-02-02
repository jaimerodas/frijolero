# frozen_string_literal: true

require 'json'
require 'date'
require 'optparse'

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
    opts.banner = <<~BANNER
      Usage: json_to_beancount.rb \
        -i input.json \
        -o output.beancount \
        -a "Liabilities:Amex"
    BANNER

    opts.on("-i", "--input FILE", "Input JSON file") do |v|
      options[:input] = v
    end

    opts.on("-o", "--output FILE", "Output Beancount file (default is the input filename but use beancount extension)") do |v|
      options[:output] = v
    end

    opts.on(
      "-a",
      "--account ACCOUNT",
      "Primary account (e.g. Assets:Cash or Liabilities:Amex)"
    ) do |v|
      options[:account] = v
    end

    opts.on(
      "-e",
      "--expense ACCOUNT",
      "Expense account (default: Expenses:FIXME)"
    ) do |v|
      options[:expense_account] = v
    end
  end

  parser.parse!

  missing = [:input, :account].select { |k| options[k].nil? }
  unless missing.empty?
    warn "Missing required options: #{missing.join(', ')}"
    warn parser
    exit 1
  end

  JsonToBeancount.convert(**options)
end
