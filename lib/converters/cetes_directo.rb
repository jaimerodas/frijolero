# frozen_string_literal: true

require 'date'

module Frijolero
  module Converters
    # A CETES Directo statement as lots. Each security has its own FIFO sub-account
    # and commodity (`<account>:CETES-280412`, `CETES-280412`), and the cash is in
    # `<account>:Cash`. The statement prints the opening and closing holdings and
    # every trade, so each month ends with a price for each holding and a balance
    # assertion on the cash and on each holding.
    #
    # - A coupon row (PAGINTCU) names no security. The ISR row with the same folio
    #   names it, so the rows of one folio become one transaction.
    # - A maturity (AMORTIZACION) sells the lots at the amount paid. The difference
    #   with their cost is interest, as in the statement's "Intereses del período".
    # - A fund sale (VTASI, the BONDDIA sweep) books that difference as a gain.
    # - The summary's cash ("Total de efectivo") and the movement table's ("Saldo
    #   final") can differ by a centavo, and the next statement starts from the
    #   summary. A "Redondeo" entry closes the gap, and the assertion uses the summary.
    class CetesDirecto < Base
      include Amounts
      extend Amounts

      PAYEE = 'CETESDirecto'
      TAX = 'tax_withholding'
      KINDS = { 'security_buy' => :buy, 'fund_buy' => :buy, 'fund_sell' => :sale, 'amortization' => :maturity,
                'interest_payment' => :coupon, 'cash_in' => :transfer, 'cash_out' => :transfer }.freeze
      # The effect of each movement type on the titles of its security.
      TITLES = { 'security_buy' => 1, 'fund_buy' => 1, 'fund_sell' => -1, 'amortization' => -1 }.freeze

      # The commodity of the security a row names, or nil for a cash row ("PESOS").
      def self.symbol(row)
        return if row['issuer'].nil? || row['issuer'] == 'PESOS'

        "#{row['issuer']}-#{row['series']}"
      end

      # What a row does to the cash.
      def self.cash(row)
        to_d(row['cash_inflow']) - to_d(row['cash_outflow'])
      end

      def initialize(targets: AccountTargets.new, **)
        super(**)
        @targets = targets
      end

      def run_to(io)
        @json = load_json
        @out = io
        write_opens
        movements.group_by { |row| row['folio'] || row.object_id }.each_value { |rows| write_folio(rows) }
        write_rounding
        write_month_end
      ensure
        @out = nil
      end

      private

      def movements = @json['movements'] || []
      def period(key) = @json.dig('statement_metadata', key)
      def closing = @json['closing_holdings'] || []

      def symbols(rows)
        (rows || []).filter_map { |row| self.class.symbol(row) }
      end

      # Every security of the month: the opening holdings and the ones bought.
      def held
        symbols(@json['opening_holdings']) | symbols(movements.select { |row| TITLES[row['movement_type']] })
      end

      # An `open` only has to come before the first posting, so the period start
      # always works.
      def write_opens
        opened = held - symbols(@json['opening_holdings'])
        opened.each { |symbol| @out.puts %(#{period('period_start')} open #{@account}:#{symbol} #{symbol} "FIFO") }
        @out.puts if opened.any?
      end

      # The ISR rows of a folio go into its first other row. An ISR row alone in
      # its folio is a withholding by itself.
      def write_folio(rows)
        taxes, others = rows.partition { |row| row['movement_type'] == TAX }
        return write_entry(taxes, ['Retención ISR', name(taxes)].compact.join(' ')) if others.empty?

        others.each_with_index do |row, index|
          entry = index.zero? ? [row, *taxes] : [row]
          write_entry(entry, *send(KINDS.fetch(row['movement_type']), row, name(entry)))
        end
      end

      # "BPAG28 280504": the first security the rows name.
      def name(rows)
        row = rows.find { |r| self.class.symbol(r) }
        "#{row['issuer']} #{row['series']}" if row
      end

      def buy(row, name)
        ["Compra #{name}", [lot(row, number(row['titles']), "{{#{money(row['cash_outflow'])} MXN}}")]]
      end

      def sale(row, name)
        ["Venta #{name}", [sold(row)], @targets.gains]
      end

      def maturity(row, name)
        ["Vencimiento #{name}", [sold(row)], @targets.interest || 'Income:FIXME']
      end

      def coupon(row, name)
        [['Pago de intereses', name].compact.join(' '), [],
         "#{@targets.interest || 'Income:FIXME'}  #{money(-to_d(row['cash_inflow']))} MXN"]
      end

      def transfer(row, _name)
        [row['movement_type'] == 'cash_in' ? 'Depósito' : 'Retiro', [], @targets.counterpart || 'Expenses:FIXME']
      end

      # `@@` with the total, because the printed price is rounded.
      def sold(row)
        lot(row, "-#{number(row['titles'])}", "{} @@ #{money(row['cash_inflow'])} MXN")
      end

      def lot(row, units, cost)
        symbol = self.class.symbol(row)
        "#{@account}:#{symbol}  #{units} #{symbol} #{cost}"
      end

      def write_entry(rows, narration, lots = [], last = nil)
        date = rows.first['settlement_date'] || rows.first['trade_date']
        write_transaction(date, narration, [*lots, *cash_postings(rows), last].compact)
      end

      # The cash moves by every row of the entry, its ISR included.
      def cash_postings(rows)
        tax = rows.select { |row| row['movement_type'] == TAX }.sum(BigDecimal(0)) { |row| to_d(row['cash_outflow']) }
        cash = "#{@account}:Cash  #{money(rows.sum(BigDecimal(0)) { |row| self.class.cash(row) })} MXN"
        tax.positive? ? [cash, "#{@targets.tax || 'Expenses:FIXME'}  #{money(tax)} MXN"] : [cash]
      end

      def write_transaction(date, narration, postings)
        @out.puts %(#{date} * "#{PAYEE}" "#{narration}")
        postings.each { |posting| @out.puts "  #{posting}" }
        @out.puts
      end

      def write_rounding
        summary = @json.dig('closing_state', 'cash')
        table = @json.dig('raw_checks', 'closing_cash_ledger_balance')
        return if summary.nil? || table.nil? || to_d(summary) == to_d(table)

        write_transaction(period('period_end'), 'Redondeo',
                          ["#{@account}:Cash  #{money(to_d(summary) - to_d(table))} MXN", @targets.gains])
      end

      # A `balance` checks the start of its day, so the assertions and the closes
      # go on the day after the period.
      def write_month_end
        last = period('period_end')
        return if last.nil?

        closing.each { |h| @out.puts "#{last} price #{self.class.symbol(h)}  #{number(h['market_price'])} MXN" }
        @out.puts
        write_balances((Date.parse(last) + 1).to_s)
      end

      def write_balances(day)
        cash = @json.dig('closing_state', 'cash')
        @out.puts "#{day} balance #{@account}:Cash  #{money(cash)} MXN" unless cash.nil?
        closing.each { |holding| write_balance(day, self.class.symbol(holding), holding['titles']) }
        (held - symbols(closing)).each { |symbol| @out.puts "#{day} close #{@account}:#{symbol}" }
      end

      def write_balance(day, symbol, titles)
        @out.puts "#{day} balance #{@account}:#{symbol}  #{number(titles)} #{symbol}"
      end
    end
  end
end
