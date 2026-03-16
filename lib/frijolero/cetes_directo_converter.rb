# frozen_string_literal: true

require "json"
require "date"

module Frijolero
  module CetesDirectoConverter
    MOVEMENT_HANDLERS = {
      "cash_in" => :handle_cash_in,
      "cash_out" => :handle_cash_out,
      "interest_payment" => :handle_interest,
      "tax_withholding" => :handle_tax
    }.freeze

    DEFAULT_GAINS_ACCOUNT = "Income:FIXME"

    def self.convert(
      input:,
      account:,
      output: nil,
      counterpart_account: nil,
      interest_account: nil,
      tax_account: nil,
      gains_account: DEFAULT_GAINS_ACCOUNT,
      **_
    )
      raise ArgumentError, "input file required" unless input
      raise ArgumentError, "account required" unless account

      output ||= File.expand_path(
        File.join(File.dirname(input), "..", "beancount",
          File.basename(input, ".json") + ".beancount")
      )

      json = JSON.parse(File.read(input))
      movements = json.fetch("movements", [])
      metadata = json.fetch("statement_metadata", {})
      opening = json.fetch("opening_state", {})
      closing = json.fetch("closing_state", {})

      total_inflows = 0.0
      total_outflows = 0.0

      File.open(output, "w") do |out|
        movements.each do |mov|
          handler = MOVEMENT_HANDLERS[mov["movement_type"]]
          next unless handler

          inflow = mov["cash_inflow"].to_f
          outflow = mov["cash_outflow"].to_f
          total_inflows += inflow
          total_outflows += outflow

          send(handler, out, mov, account,
            counterpart_account: counterpart_account,
            interest_account: interest_account,
            tax_account: tax_account)
        end

        write_mark_to_market(out, account, gains_account,
          opening["total"].to_f, closing["total"].to_f,
          total_inflows, total_outflows,
          metadata["period_end"])

        write_balance_assertion(out, account,
          closing["total"].to_f, metadata["period_end"])
      end

      output
    end

    private_class_method def self.handle_cash_in(out, mov, account, counterpart_account:, **)
      date = mov["settlement_date"] || mov["trade_date"]
      amount = mov["cash_inflow"].to_f
      target = counterpart_account || "Expenses:FIXME"

      out.puts %(#{date} * "CETESDirecto" "Depósito")
      out.puts "  #{account}  #{format("%.2f", amount)} MXN"
      out.puts "  #{target}"
      out.puts
    end

    private_class_method def self.handle_cash_out(out, mov, account, counterpart_account:, **)
      date = mov["settlement_date"] || mov["trade_date"]
      amount = mov["cash_outflow"].to_f
      target = counterpart_account || "Expenses:FIXME"

      out.puts %(#{date} * "CETESDirecto" "Retiro")
      out.puts "  #{account}  #{format("%.2f", -amount)} MXN"
      out.puts "  #{target}"
      out.puts
    end

    private_class_method def self.handle_interest(out, mov, account, interest_account:, **)
      date = mov["settlement_date"] || mov["trade_date"]
      amount = mov["cash_inflow"].to_f
      issuer = mov["issuer"]
      series = mov["series"]
      target = interest_account || "Income:FIXME"

      narration = "Pago de intereses"
      narration += " #{issuer} #{series}" if issuer && issuer != "PESOS"

      out.puts %(#{date} * "CETESDirecto" "#{narration}")
      out.puts "  #{account}  #{format("%.2f", amount)} MXN"
      out.puts "  #{target}"
      out.puts
    end

    private_class_method def self.handle_tax(out, mov, account, tax_account:, **)
      date = mov["settlement_date"] || mov["trade_date"]
      amount = mov["cash_outflow"].to_f
      issuer = mov["issuer"]
      series = mov["series"]
      target = tax_account || "Expenses:FIXME"

      narration = "Retención ISR"
      narration += " #{issuer} #{series}" if issuer && issuer != "PESOS"

      out.puts %(#{date} * "CETESDirecto" "#{narration}")
      out.puts "  #{account}  #{format("%.2f", -amount)} MXN"
      out.puts "  #{target}"
      out.puts
    end

    private_class_method def self.write_mark_to_market(out, account, gains_account,
      opening_total, closing_total,
      total_inflows, total_outflows,
      period_end)
      return unless period_end

      expected = opening_total + total_inflows - total_outflows
      unrealized = closing_total - expected

      return if unrealized.abs < 0.005

      out.puts %(#{period_end} * "CETESDirecto" "Plusvalía del periodo")
      out.puts "  #{account}  #{format("%.2f", unrealized)} MXN"
      out.puts "  #{gains_account}"
      out.puts
    end

    private_class_method def self.write_balance_assertion(out, account, closing_total, period_end)
      return unless period_end

      assertion_date = (Date.parse(period_end) + 1).strftime("%Y-%m-%d")
      out.puts "#{assertion_date} balance #{account}  #{format("%.2f", closing_total)} MXN"
    end
  end
end
