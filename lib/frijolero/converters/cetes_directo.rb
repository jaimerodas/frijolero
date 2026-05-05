# frozen_string_literal: true

require 'date'

module Frijolero
  module Converters
    class CetesDirecto < Base
      MOVEMENT_HANDLERS = {
        'cash_in' => :handle_cash_in,
        'cash_out' => :handle_cash_out,
        'interest_payment' => :handle_interest,
        'tax_withholding' => :handle_tax
      }.freeze

      DEFAULT_GAINS_ACCOUNT = AccountTargets::DEFAULT_GAINS

      def initialize(targets: AccountTargets.new, **kwargs)
        super(**kwargs)
        @targets = targets
      end

      def run_to(io)
        json = load_json
        @inflows = 0.0
        @outflows = 0.0
        @opening_total = json.fetch('opening_state', {})['total'].to_f
        @closing_total = json.fetch('closing_state', {})['total'].to_f
        @period_end = json.fetch('statement_metadata', {})['period_end']
        @out = io

        process_movements(json.fetch('movements', []))
      ensure
        @out = nil
      end

      private

      def process_movements(movements)
        movements.each { |mov| dispatch_movement(mov) }
        write_mark_to_market
        write_balance_assertion
      end

      def dispatch_movement(mov)
        handler = MOVEMENT_HANDLERS[mov['movement_type']]
        return unless handler

        @inflows += mov['cash_inflow'].to_f
        @outflows += mov['cash_outflow'].to_f
        send(handler, mov)
      end

      def handle_cash_in(mov)
        write_simple_movement(mov, mov['cash_inflow'].to_f, 'Depósito',
                              @targets.counterpart || 'Expenses:FIXME')
      end

      def handle_cash_out(mov)
        write_simple_movement(mov, -mov['cash_outflow'].to_f, 'Retiro',
                              @targets.counterpart || 'Expenses:FIXME')
      end

      def handle_interest(mov)
        narration = with_issuer_series('Pago de intereses', mov)
        write_simple_movement(mov, mov['cash_inflow'].to_f, narration,
                              @targets.interest || 'Income:FIXME')
      end

      def handle_tax(mov)
        narration = with_issuer_series('Retención ISR', mov)
        write_simple_movement(mov, -mov['cash_outflow'].to_f, narration,
                              @targets.tax || 'Expenses:FIXME')
      end

      def write_simple_movement(mov, amount, narration, target)
        date = mov['settlement_date'] || mov['trade_date']
        @out.puts %(#{date} * "CETESDirecto" "#{narration}")
        @out.puts "  #{@account}  #{format('%.2f', amount)} MXN"
        @out.puts "  #{target}"
        @out.puts
      end

      def with_issuer_series(base, mov)
        issuer = mov['issuer']
        return base if issuer.nil? || issuer == 'PESOS'

        "#{base} #{issuer} #{mov['series']}"
      end

      def write_mark_to_market
        return unless @period_end

        unrealized = @closing_total - (@opening_total + @inflows - @outflows)
        return if unrealized.abs < 0.005

        @out.puts %(#{@period_end} * "CETESDirecto" "Plusvalía del periodo")
        @out.puts "  #{@account}  #{format('%.2f', unrealized)} MXN"
        @out.puts "  #{@targets.gains}"
        @out.puts
      end

      def write_balance_assertion
        return unless @period_end

        assertion_date = (Date.parse(@period_end) + 1).strftime('%Y-%m-%d')
        @out.puts "#{assertion_date} balance #{@account}  #{format('%.2f', @closing_total)} MXN"
      end
    end
  end
end
