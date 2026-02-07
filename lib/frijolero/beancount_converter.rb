# frozen_string_literal: true

require "json"
require "date"

module Frijolero
  module BeancountConverter
    DEFAULT_EXPENSE_ACCOUNT = "Expenses:FIXME"

    def self.convert(
      input:,
      account:,
      output: nil,
      expense_account: DEFAULT_EXPENSE_ACCOUNT
    )
      raise ArgumentError, "input file required" unless input
      raise ArgumentError, "account required" unless account

      output ||= File.expand_path(File.join(File.dirname(input), "..", "beancount", File.basename(input, ".json") + ".beancount"))

      json = JSON.parse(File.read(input))

      File.open(output, "w") do |out|
        json.fetch("transactions", []).each do |tx|
          date = Date.parse(tx.fetch("date")).strftime("%Y-%m-%d")
          description = (tx["description"] || "").gsub(/\s+/, " ").strip
          narration = tx["narration"]
          payee = tx["payee"]
          amount = tx.fetch("amount").to_f
          currency = tx["currency"] || "MXN"
          set_expense_account = tx["expense_account"] || expense_account

          if !narration
            narration = description
            description = false
          end

          if payee
            out.puts %(#{date} * "#{payee}" "#{narration}")
          else
            out.puts %(#{date} * "#{narration}")
          end

          if description
            out.puts %(  source_desc: "#{description}")
          end

          out.puts "  #{account}  #{format("%.2f", amount)} #{currency}"
          out.puts "  #{set_expense_account}"
          out.puts
        end
      end

      output
    end
  end
end
