# frozen_string_literal: true

require 'date'

module Frijolero
  module Converters
    # Plata Inversiones (VestFi / Alpaca) brokerage statements. USD, Spanish labels.
    #
    # Two things drive the output shape:
    #
    # 1. The statement's `Importe` is authoritative; `Precio unitario` is rounded and
    #    does not always multiply back to it (14 VGK x 84.15 = 1178.10, reported
    #    1178.16). Buys therefore use total-cost syntax so the ledger balances.
    # 2. Corporate actions (splits) change the share count with no movement row. The
    #    difference is detectable against the portfolio table and is emitted as a
    #    FIXME dated at period start, so later sales in the same period still have
    #    units to draw from.
    class Plata < Base
      include Amounts

      PAYEE = 'Plata'

      TRANSACTION_HANDLERS = {
        'deposit' => :handle_deposit,
        'withdrawal' => :handle_withdrawal,
        'buy' => :handle_buy,
        'sell' => :handle_sell,
        'dividend' => :handle_dividend,
        'interest' => :handle_interest,
        'fee' => :handle_fee,
        'tax' => :handle_tax
      }.freeze

      def initialize(targets: AccountTargets.new, **kwargs)
        super(**kwargs)
        @targets = targets
      end

      def run_to(io)
        json = load_json
        @out = io
        load_statement(json)

        write_entries(json.fetch('transactions', []))
      ensure
        @out = nil
      end

      private

      attr_reader :period_start, :period_end

      def write_entries(transactions)
        write_unit_adjustments(transactions)
        transactions.each { |transaction| dispatch(transaction) }
        write_unreported_charges(transactions)
        write_price_declarations
        write_cash_balance
      end

      def load_statement(json)
        @currency = json['currency'] || 'USD'
        @holdings = json.fetch('holdings', [])
        period = json.fetch('statement_period', {})
        @period_start = period['start_date']
        @cash = json['cash'] || {}
        @service_fees = json['service_fees'] || []
        @isr_items = json['isr_withheld_items'] || []
        # Normalised once: an unparseable period end must not reach the price
        # directives or the balance assertion, both of which emit it as a date.
        @period_end = parsed_date(period['end_date'])
      end

      def parsed_date(value)
        Date.parse(value.to_s).to_s
      rescue Date::Error
        nil
      end

      # A `balance` directive asserts the balance at the START of its date, so the
      # statement's closing cash is dated the day after the period ends -- dating it
      # at period end would exclude any movement falling on the last day.
      def write_cash_balance
        closing = @cash['current']
        return if closing.nil? || period_end.nil?

        @out.puts
        @out.puts "#{assertion_date} balance #{@account}:Cash " \
                  "#{grouped(closing)} #{@currency}"
      end

      def assertion_date
        (Date.parse(period_end) + 1).to_s
      end

      def write_unit_adjustments(transactions)
        UnitReconciler.new(@holdings, transactions).mismatches.each do |mismatch|
          write_unit_adjustment(mismatch)
        end
      end

      # The schema's transaction_type enum includes "other" -- the extractor's
      # "could not classify this" bucket -- which no handler covers. Dropping such a
      # row would take its cash movement with it, and the only symptom would be the
      # closing balance assertion failing with nothing to point at.
      def dispatch(transaction)
        handler = TRANSACTION_HANDLERS[transaction['transaction_type']]
        return send(handler, transaction) if handler

        write_unclassified(transaction)
      end

      def write_unclassified(transaction)
        label = transaction['description_raw'] || transaction['transaction_type']
        write_header(transaction, "FIXME movimiento sin clasificar: #{label}", flag: '!')
        write_posting("#{@account}:Cash", amount_of(transaction))
        @out.puts '  Equity:FIXME'
        @out.puts
      end

      def handle_deposit(transaction)
        write_cash_movement(transaction, amount_of(transaction),
                            transaction['description_raw'] || 'Depósito',
                            @targets.counterpart || 'Assets:FIXME')
      end

      def handle_withdrawal(transaction)
        write_cash_movement(transaction, -amount_of(transaction),
                            transaction['description_raw'] || 'Retiro',
                            @targets.counterpart || 'Assets:FIXME')
      end

      def handle_buy(transaction)
        ticker = transaction['ticker']
        amount = amount_of(transaction)
        commission = commission_of(transaction)

        write_header(transaction, "Compra #{ticker}")
        @out.puts "  #{@account}:#{ticker}  #{units_of(transaction)} #{ticker} " \
                  "{{#{money(amount)} #{@currency}}}"
        write_commission(commission)
        write_posting("#{@account}:Cash", -(amount + commission))
        @out.puts
      end

      def handle_sell(transaction)
        ticker = transaction['ticker']
        amount = amount_of(transaction)
        commission = commission_of(transaction)

        # Total proceeds, for the same reason buys use total cost: the printed unit
        # price is rounded, and a per-unit @ would quietly book the difference as
        # capital gain via the elastic gains posting.
        write_header(transaction, "Venta #{ticker}")
        @out.puts "  #{@account}:#{ticker}  -#{units_of(transaction)} #{ticker} " \
                  "{} @@ #{money(amount)} #{@currency}"
        write_commission(commission)
        write_posting("#{@account}:Cash", amount - commission)
        @out.puts "  #{@targets.gains}"
        @out.puts
      end

      # `amount` is the cash actually credited; the withholding column is reported
      # alongside it, so gross income is the sum of the two.
      def handle_dividend(transaction)
        ticker = transaction['ticker']
        narration = ticker ? "Dividendo #{ticker}" : 'Dividendo'

        write_header(transaction, narration)
        write_posting("#{@account}:Cash", amount_of(transaction))
        withheld = withholding_of(transaction)
        write_posting(@targets.withholding || 'Expenses:FIXME', withheld) if withheld.positive?
        @out.puts "  #{@targets.dividend || 'Income:FIXME'}"
        @out.puts
      end

      def handle_interest(transaction)
        write_cash_movement(transaction, amount_of(transaction),
                            transaction['description_raw'] || 'Intereses',
                            @targets.interest || 'Income:FIXME')
      end

      def handle_fee(transaction)
        write_cash_movement(transaction, -amount_of(transaction),
                            transaction['description_raw'] || 'Comisión',
                            @targets.fees || 'Expenses:FIXME')
      end

      def handle_tax(transaction)
        write_cash_movement(transaction, -amount_of(transaction),
                            transaction['description_raw'] || 'ISR retenido',
                            @targets.tax || 'Expenses:FIXME')
      end

      # Dated at period start so the sales that follow still have units to draw
      # from, and left as a FIXME because the correct cost basis for a corporate
      # action cannot be inferred from the statement alone.
      def write_unit_adjustment(mismatch)
        ticker = mismatch.ticker
        @out.puts %(#{period_start} ! "#{PAYEE}" "FIXME ajuste de títulos no reportado #{ticker}")
        @out.puts "  ; esperado #{number(mismatch.expected)} #{ticker}, " \
                  "reportado #{number(mismatch.reported)} #{ticker} #{hint(mismatch)}"
        @out.puts "  #{@account}:#{ticker}  #{number(mismatch.delta)} #{ticker} " \
                  "#{adjustment_cost(mismatch)}"
        @out.puts '  Equity:FIXME'
        @out.puts
      end

      # Shares appearing against a zero opening position cannot be a split -- nothing
      # splits from nothing -- so it is a grant or an unreported transfer in.
      def hint(mismatch)
        return '(¿acciones recibidas?)' if mismatch.expected.zero?

        mismatch.delta.negative? ? '(¿split inverso?)' : '(¿split?)'
      end

      # A negative delta is a reduction, and asking for a lot at 0.00 finds nothing.
      # Leave the cost open so the account's booking method picks the lot.
      def adjustment_cost(mismatch)
        mismatch.delta.negative? ? '{}' : "{{0.00 #{@currency}}}"
      end

      # "Comisiones y gastos por servicios" restates the per-trade commissions rather
      # than charging anything new -- in every statement processed so far each row
      # matches a movement's `commission_total`. Rather than trust that indefinitely,
      # flag the excess, so a standalone advisory fee cannot leave the account
      # unrecorded. "Impuesto sobre la renta retenido" has always been empty and has
      # no movement-row equivalent at all, so every entry there is flagged.
      def write_unreported_charges(transactions)
        billed = transactions.sum { |transaction| commission_of(transaction) }
        listed = @service_fees.sum { |fee| to_d(fee['amount']) }
        write_unreported_charge('comisiones por servicios', listed - billed) if listed > billed

        @isr_items.each do |item|
          write_unreported_charge(item['description'] || 'ISR retenido', to_d(item['amount']))
        end
      end

      def write_unreported_charge(label, amount)
        return unless amount.positive?

        @out.puts %(#{period_end} ! "#{PAYEE}" "FIXME cargo no reflejado en movimientos: #{label}")
        write_posting("#{@account}:Cash", -amount)
        @out.puts "  #{@targets.fees || 'Expenses:FIXME'}"
        @out.puts
      end

      def write_cash_movement(transaction, amount, narration, target)
        write_header(transaction, narration)
        write_posting("#{@account}:Cash", amount)
        @out.puts "  #{target}"
        @out.puts
      end

      def write_commission(commission)
        return unless commission.positive?

        write_posting(@targets.fees || 'Expenses:FIXME', commission)
      end

      def write_posting(account, amount)
        @out.puts "  #{account}  #{money(amount)} #{@currency}"
      end

      def write_header(transaction, narration, flag: '*')
        @out.puts %(#{transaction['trade_date']} #{flag} "#{PAYEE}" "#{narration}")
      end

      def write_price_declarations
        @holdings.each do |holding|
          ticker = holding['ticker']
          price = holding['market_price_current']
          next if ticker.nil? || price.nil? || period_end.nil?

          @out.puts "#{period_end} price #{ticker}  #{price} #{@currency}"
        end
      end

      def amount_of(transaction)
        to_d(transaction['amount'])
      end

      def commission_of(transaction)
        to_d(transaction['commission_total'])
      end

      def withholding_of(transaction)
        to_d(transaction['withholding'])
      end

      def units_of(transaction)
        number(transaction['units'])
      end
    end
  end
end
