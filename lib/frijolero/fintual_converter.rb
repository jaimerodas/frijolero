# frozen_string_literal: true

require "json"

module Frijolero
  module FintualConverter
    TRANSACTION_HANDLERS = {
      "deposit" => :handle_deposit,
      "withdrawal" => :handle_withdrawal,
      "buy" => :handle_buy,
      "sell" => :handle_sell,
      "dividend" => :handle_dividend,
      "interest" => :handle_interest
    }.freeze

    DEFAULT_GAINS_ACCOUNT = "Income:FIXME"

    def self.convert(
      input:,
      account:,
      output: nil,
      counterpart_account: nil,
      dividend_account: nil,
      interest_account: nil,
      gains_account: DEFAULT_GAINS_ACCOUNT,
      **_
    )
      raise ArgumentError, "input file required" unless input
      raise ArgumentError, "account required" unless account

      output ||= File.expand_path(
        File.join(File.dirname(input), "..", "beancount",
          File.basename(input, ".json") + ".beancount")
      )

      json = JSON.parse(File.read(input, encoding: "UTF-8"))
      txs = json.fetch("transactions", [])
      holdings = json.fetch("holdings_current", [])
      currency = json["currency"] || "MXN"
      payee = json["provider"] || "Fintual"

      File.open(output, "w") do |out|
        txs.each do |tx|
          handler = TRANSACTION_HANDLERS[tx["transaction_type"]]
          next unless handler

          send(handler, out, tx, account, currency, payee,
            counterpart_account: counterpart_account,
            dividend_account: dividend_account,
            interest_account: interest_account,
            gains_account: gains_account)
        end

        write_price_declarations(out, holdings, currency)
      end

      output
    end

    private_class_method def self.write_price_declarations(out, holdings, currency)
      holdings.each do |h|
        commodity = h["commodity"]
        price = h["price_per_unit"]
        date = h["price_date"]
        next if commodity.nil? || price.nil? || date.nil?

        out.puts "#{date} price #{commodity}  #{price} #{currency}"
      end
    end

    private_class_method def self.handle_deposit(out, tx, account, currency, payee, counterpart_account:, **)
      amount = tx["reported_amount"].to_f
      target = counterpart_account || "Assets:FIXME"
      narration = tx["description"] || "Depósito"

      out.puts %(#{tx["trade_date"]} * "#{payee}" "#{narration}")
      out.puts "  #{account}:Cash  #{format("%.2f", amount)} #{currency}"
      out.puts "  #{target}"
      out.puts
    end

    private_class_method def self.handle_withdrawal(out, tx, account, currency, payee, counterpart_account:, **)
      amount = tx["reported_amount"].to_f
      target = counterpart_account || "Assets:FIXME"
      narration = tx["description"] || "Retiro"

      out.puts %(#{tx["trade_date"]} * "#{payee}" "#{narration}")
      out.puts "  #{account}:Cash  #{format("%.2f", -amount)} #{currency}"
      out.puts "  #{target}"
      out.puts
    end

    private_class_method def self.handle_buy(out, tx, account, currency, payee, **)
      commodity = tx["commodity"]
      units = format_units(tx["units"])
      price = tx["price_per_unit"]
      cash_amount = tx["reported_amount"].to_f
      narration = build_fund_narration(tx["description"] || "Compra", tx["fund_code_raw"])

      out.puts %(#{tx["trade_date"]} * "#{payee}" "#{narration}")
      out.puts "  #{account}:#{commodity}  #{units} #{commodity} {#{price} #{currency}}"
      out.puts "  #{account}:Cash  #{format("%.2f", -cash_amount)} #{currency}"
      out.puts
    end

    private_class_method def self.handle_sell(out, tx, account, currency, payee, gains_account:, **)
      commodity = tx["commodity"]
      units = format_units(tx["units"])
      price = tx["price_per_unit"]
      cash_amount = tx["reported_amount"].to_f
      narration = build_fund_narration(tx["description"] || "Venta", tx["fund_code_raw"])

      out.puts %(#{tx["trade_date"]} * "#{payee}" "#{narration}")
      out.puts "  #{account}:#{commodity}  -#{units} #{commodity} {} @ #{price} #{currency}"
      out.puts "  #{account}:Cash  #{format("%.2f", cash_amount)} #{currency}"
      out.puts "  #{gains_account}"
      out.puts
    end

    private_class_method def self.handle_dividend(out, tx, account, currency, payee, dividend_account:, **)
      amount = tx["reported_amount"].to_f
      target = dividend_account || "Income:FIXME"
      narration = tx["description"] || "Dividendo"

      out.puts %(#{tx["trade_date"]} * "#{payee}" "#{narration}")
      out.puts "  #{account}:Cash  #{format("%.2f", amount)} #{currency}"
      out.puts "  #{target}"
      out.puts
    end

    private_class_method def self.handle_interest(out, tx, account, currency, payee, interest_account:, **)
      amount = tx["reported_amount"].to_f
      target = interest_account || "Income:FIXME"
      narration = tx["description"] || "Intereses"

      out.puts %(#{tx["trade_date"]} * "#{payee}" "#{narration}")
      out.puts "  #{account}:Cash  #{format("%.2f", amount)} #{currency}"
      out.puts "  #{target}"
      out.puts
    end

    private_class_method def self.format_units(units_str)
      return units_str if units_str.nil?
      cleaned = units_str.to_s.delete(",")
      value = cleaned.to_f
      (value == value.to_i) ? value.to_i.to_s : cleaned
    end

    private_class_method def self.build_fund_narration(description, fund_code)
      return description if fund_code.nil? || fund_code.empty?
      "#{description} #{fund_code}"
    end
  end
end
