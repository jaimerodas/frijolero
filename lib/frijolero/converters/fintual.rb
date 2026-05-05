# frozen_string_literal: true

module Frijolero
  module Converters
    class Fintual < Base
      TRANSACTION_HANDLERS = {
        'deposit' => :handle_deposit,
        'withdrawal' => :handle_withdrawal,
        'buy' => :handle_buy,
        'sell' => :handle_sell,
        'dividend' => :handle_dividend,
        'interest' => :handle_interest
      }.freeze

      DEFAULT_GAINS_ACCOUNT = AccountTargets::DEFAULT_GAINS

      def initialize(targets: AccountTargets.new, **kwargs)
        super(**kwargs)
        @targets = targets
      end

      def run_to(io)
        json = load_json
        @holdings = json.fetch('holdings_current', [])
        @currency = json['currency'] || 'MXN'
        @payee = json['provider'] || 'Fintual'
        @out = io

        process_transactions(json.fetch('transactions', []))
      ensure
        @out = nil
      end

      private

      def process_transactions(transactions)
        transactions.each { |transaction| dispatch(transaction) }
        write_price_declarations
      end

      def dispatch(transaction)
        handler = TRANSACTION_HANDLERS[transaction['transaction_type']]
        send(handler, transaction) if handler
      end

      def handle_deposit(transaction)
        write_cash_movement(transaction, transaction['reported_amount'].to_f,
                            transaction['description'] || 'Depósito',
                            @targets.counterpart || 'Assets:FIXME')
      end

      def handle_withdrawal(transaction)
        write_cash_movement(transaction, -transaction['reported_amount'].to_f,
                            transaction['description'] || 'Retiro',
                            @targets.counterpart || 'Assets:FIXME')
      end

      def handle_buy(transaction)
        commodity = transaction['commodity']
        units = format_units(transaction['units'])
        cash_amount = transaction['reported_amount'].to_f
        narration = build_fund_narration(transaction['description'] || 'Compra', transaction['fund_code_raw'])

        write_header(transaction['trade_date'], narration)
        @out.puts "  #{@account}:#{commodity}  #{units} #{commodity} {#{transaction['price_per_unit']} #{@currency}}"
        @out.puts "  #{@account}:Cash  #{format('%.2f', -cash_amount)} #{@currency}"
        @out.puts
      end

      def handle_sell(transaction)
        commodity = transaction['commodity']
        units = format_units(transaction['units'])
        cash_amount = transaction['reported_amount'].to_f
        narration = build_fund_narration(transaction['description'] || 'Venta', transaction['fund_code_raw'])

        write_header(transaction['trade_date'], narration)
        @out.puts "  #{@account}:#{commodity}  -#{units} #{commodity} {} @ #{transaction['price_per_unit']} #{@currency}"
        @out.puts "  #{@account}:Cash  #{format('%.2f', cash_amount)} #{@currency}"
        @out.puts "  #{@targets.gains}"
        @out.puts
      end

      def handle_dividend(transaction)
        write_cash_movement(transaction, transaction['reported_amount'].to_f,
                            transaction['description'] || 'Dividendo',
                            @targets.dividend || 'Income:FIXME')
      end

      def handle_interest(transaction)
        write_cash_movement(transaction, transaction['reported_amount'].to_f,
                            transaction['description'] || 'Intereses',
                            @targets.interest || 'Income:FIXME')
      end

      def write_cash_movement(transaction, amount, narration, target)
        write_header(transaction['trade_date'], narration)
        @out.puts "  #{@account}:Cash  #{format('%.2f', amount)} #{@currency}"
        @out.puts "  #{target}"
        @out.puts
      end

      def write_header(date, narration)
        @out.puts %(#{date} * "#{@payee}" "#{narration}")
      end

      def write_price_declarations
        @holdings.each do |holding|
          commodity = holding['commodity']
          price = holding['price_per_unit']
          date = holding['price_date']
          next if commodity.nil? || price.nil? || date.nil?

          @out.puts "#{date} price #{commodity}  #{price} #{@currency}"
        end
      end

      def format_units(units_str)
        return units_str if units_str.nil?

        cleaned = units_str.to_s.delete(',')
        value = cleaned.to_f
        value == value.to_i ? value.to_i.to_s : cleaned
      end

      def build_fund_narration(description, fund_code)
        return description if fund_code.nil? || fund_code.empty?

        "#{description} #{fund_code}"
      end
    end
  end
end
