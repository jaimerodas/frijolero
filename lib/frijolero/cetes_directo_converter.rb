# frozen_string_literal: true

require "json"
require "date"

module Frijolero
  class CetesDirectoConverter
    MOVEMENT_HANDLERS = {
      "cash_in" => :handle_cash_in,
      "cash_out" => :handle_cash_out,
      "interest_payment" => :handle_interest,
      "tax_withholding" => :handle_tax
    }.freeze

    DEFAULT_GAINS_ACCOUNT = "Income:FIXME"

    def self.convert(**kwargs)
      new(**kwargs).convert
    end

    def initialize(
      input:,
      account:,
      output: nil,
      counterpart_account: nil,
      interest_account: nil,
      tax_account: nil,
      gains_account: DEFAULT_GAINS_ACCOUNT
    )
      raise ArgumentError, "input file required" unless input
      raise ArgumentError, "account required" unless account

      @input = input
      @account = account
      @output = output
      @counterpart_account = counterpart_account
      @interest_account = interest_account
      @tax_account = tax_account
      @gains_account = gains_account
    end

    def convert
      output = @output || File.expand_path(
        File.join(File.dirname(@input), "..", "beancount",
          File.basename(@input, ".json") + ".beancount")
      )

      File.open(output, "w") { |file| run_to(file) }

      output
    end

    def run_to(io)
      json = JSON.parse(File.read(@input))
      movements = json.fetch("movements", [])
      metadata = json.fetch("statement_metadata", {})
      opening = json.fetch("opening_state", {})
      closing = json.fetch("closing_state", {})

      @inflows = 0.0
      @outflows = 0.0
      @opening_total = opening["total"].to_f
      @closing_total = closing["total"].to_f
      @period_end = metadata["period_end"]
      @out = io

      begin
        movements.each do |mov|
          handler = MOVEMENT_HANDLERS[mov["movement_type"]]
          next unless handler

          @inflows += mov["cash_inflow"].to_f
          @outflows += mov["cash_outflow"].to_f

          send(handler, mov)
        end

        write_mark_to_market
        write_balance_assertion
      ensure
        @out = nil
      end
    end

    private

    def handle_cash_in(mov)
      date = mov["settlement_date"] || mov["trade_date"]
      amount = mov["cash_inflow"].to_f
      target = @counterpart_account || "Expenses:FIXME"

      @out.puts %(#{date} * "CETESDirecto" "Depósito")
      @out.puts "  #{@account}  #{format("%.2f", amount)} MXN"
      @out.puts "  #{target}"
      @out.puts
    end

    def handle_cash_out(mov)
      date = mov["settlement_date"] || mov["trade_date"]
      amount = mov["cash_outflow"].to_f
      target = @counterpart_account || "Expenses:FIXME"

      @out.puts %(#{date} * "CETESDirecto" "Retiro")
      @out.puts "  #{@account}  #{format("%.2f", -amount)} MXN"
      @out.puts "  #{target}"
      @out.puts
    end

    def handle_interest(mov)
      date = mov["settlement_date"] || mov["trade_date"]
      amount = mov["cash_inflow"].to_f
      issuer = mov["issuer"]
      series = mov["series"]
      target = @interest_account || "Income:FIXME"

      narration = "Pago de intereses"
      narration += " #{issuer} #{series}" if issuer && issuer != "PESOS"

      @out.puts %(#{date} * "CETESDirecto" "#{narration}")
      @out.puts "  #{@account}  #{format("%.2f", amount)} MXN"
      @out.puts "  #{target}"
      @out.puts
    end

    def handle_tax(mov)
      date = mov["settlement_date"] || mov["trade_date"]
      amount = mov["cash_outflow"].to_f
      issuer = mov["issuer"]
      series = mov["series"]
      target = @tax_account || "Expenses:FIXME"

      narration = "Retención ISR"
      narration += " #{issuer} #{series}" if issuer && issuer != "PESOS"

      @out.puts %(#{date} * "CETESDirecto" "#{narration}")
      @out.puts "  #{@account}  #{format("%.2f", -amount)} MXN"
      @out.puts "  #{target}"
      @out.puts
    end

    def write_mark_to_market
      return unless @period_end

      expected = @opening_total + @inflows - @outflows
      unrealized = @closing_total - expected

      return if unrealized.abs < 0.005

      @out.puts %(#{@period_end} * "CETESDirecto" "Plusvalía del periodo")
      @out.puts "  #{@account}  #{format("%.2f", unrealized)} MXN"
      @out.puts "  #{@gains_account}"
      @out.puts
    end

    def write_balance_assertion
      return unless @period_end

      assertion_date = (Date.parse(@period_end) + 1).strftime("%Y-%m-%d")
      @out.puts "#{assertion_date} balance #{@account}  #{format("%.2f", @closing_total)} MXN"
    end
  end
end
