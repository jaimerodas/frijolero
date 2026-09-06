# frozen_string_literal: true

require 'date'
require_relative '../beancount/quoting'

module Frijolero
  module Converters
    # Alpaca monthly brokerage statements, held through the Mexican advisor Plata.
    # USD, English labels, and — unlike the advisor's own summary statement this
    # replaced — internally complete: every Cash Summary line is reproducible from
    # the detail tables to the cent.
    #
    # Three things drive the output shape:
    #
    # 1. The Amount column is authoritative; Price is rounded and does not always
    #    multiply back to it (10 VGK x 79.59 = 795.90, reported 795.91). Buys use
    #    total-cost syntax so the ledger balances.
    # 2. Corporate actions arrive as explicit REMOVE/ADD rows carrying old and new
    #    cost prices, so splits and spinoffs are booked as basis-conserving
    #    rebasings rather than guessed at from a change in share count.
    # 3. `High-Yield Cash Sweep` rows move cash between the brokerage and the FDIC
    #    partner banks. They are absent from the Cash Summary, so emitting them
    #    would double-count; they are skipped and reported in the header.
    class Plata < Base
      include Amounts

      PAYEE = 'Plata'
      SWEEP = 'High-Yield Cash Sweep'
      # Sales emit `{}` reductions, which are ambiguous under Beancount's default
      # STRICT booking as soon as a commodity has more than one lot.
      BOOKING = '"FIFO"'
      DEFAULT_OPENING = 'Equity:Opening-Balances'
      CORPORATE_ACTIONS = ['Stock Split', 'Stock SpinOff'].freeze
      SECURITY_TRANSFER = 'ACATS IN/OUT (Securities)'

      HANDLERS = {
        'Trade Entry' => :write_trade,
        'Stock Split' => :write_corporate_action,
        'Stock SpinOff' => :write_corporate_action,
        SECURITY_TRANSFER => :write_security_transfer,
        'ACATS IN/OUT (Cash)' => :write_cash_transfer,
        'Dividends' => :write_dividend,
        'Div. Adj(NRA Withheld)' => :write_withholding,
        'Cash Interest' => :write_interest,
        'Fee' => :write_fee,
        'Journal Entry(Cash)' => :write_journal_entry,
        SWEEP => :skip_sweep
      }.freeze

      def initialize(targets: AccountTargets.new, **)
        super(**)
        @targets = targets
      end

      def run_to(io)
        json = load_json
        @out = io
        load_statement(json)
        write_statement(Entry.stream(json))
      ensure
        @out = nil
      end

      private

      # Ordered so the file reads the way the statement does: what it claimed, which
      # accounts came into existence, the movements themselves, then the closing
      # facts that check them and the accounts the period emptied.
      def write_statement(stream)
        positions = Positions.new(@holdings, stream)

        write_file_header(stream)
        write_opens(positions)
        groups(stream).each { |group| dispatch(group) }
        write_price_declarations
        write_balances
        write_closes(positions)
      end

      attr_reader :period_end

      def load_statement(json)
        @currency = json['currency'] || 'USD'
        @provider = json['provider']
        @holdings = json['holdings'] || []
        @cash_summary = json['cash_summary'] || {}
        @cash_holding = json['cash_holding'] || {}
        @realized = json['realized_gain_loss'] || {}
        load_period(json['statement_period'] || {})
      end

      # Normalised once: an unparseable period end must not reach the price
      # directives or the balance assertions, both of which emit it as a date.
      def load_period(period)
        @period_start = parsed_date(period['start_date'])
        @period_end = parsed_date(period['end_date'])
      end

      def parsed_date(value)
        Date.parse(value.to_s).to_s
      rescue Date::Error
        nil
      end

      # --- grouping -----------------------------------------------------------

      # Corporate actions and securities transfers are several rows describing one
      # event. Everything else is one row per transaction. Entry.stream keeps the
      # rows of an event adjacent, so a chunk on the group key is enough.
      def groups(stream)
        stream.chunk_while do |left, right|
          key = group_key(left)
          !key.nil? && key == group_key(right)
        end
      end

      # A split's rows differ in description ("REMOVE, ..." against "ADD, ..."), so
      # they group on the date alone. A statement can carry two unrelated ACATS
      # transfers on one date, which the transfer reference distinguishes.
      def group_key(entry)
        case entry.entry_type
        when *CORPORATE_ACTIONS then [entry.date, entry.entry_type]
        when SECURITY_TRANSFER then [entry.date, entry.entry_type, entry.description]
        end
      end

      # An unrecognised entry type must not be dropped: its cash movement would go
      # with it, and the only symptom would be a failed balance assertion with
      # nothing to point at.
      def dispatch(group)
        handler = HANDLERS[group.first.entry_type]
        return write_unclassified(group.first) unless handler

        send(handler, group)
      end

      # --- transaction writers ------------------------------------------------

      def write_trade(group)
        entry = group.first
        sell?(entry) ? write_sell(entry) : write_buy(entry)
      end

      def sell?(entry)
        return entry.side.to_s.casecmp('sell').zero? unless entry.side.nil?

        entry.quantity.negative?
      end

      def write_buy(entry)
        write_header(entry, "Buy #{entry.symbol}")
        write_units(entry.symbol, entry.quantity, "{{#{money(entry.amount.abs)} #{@currency}}}")
        write_commission(entry)
        write_posting(cash_account, entry.amount - entry.commission)
        @out.puts
      end

      # Total proceeds, for the same reason buys use total cost: the printed unit
      # price is rounded, and a per-unit @ would quietly book the difference as
      # capital gain via the elastic gains posting.
      def write_sell(entry)
        write_header(entry, "Sell #{entry.symbol}")
        write_units(entry.symbol, entry.quantity, "{} @@ #{money(entry.amount)} #{@currency}")
        write_commission(entry)
        write_posting(cash_account, entry.amount - entry.commission)
        @out.puts "  #{@targets.gains}"
        @out.puts
      end

      def write_corporate_action(group)
        action = CorporateAction.new(group)
        write_action_header(group.first, action)
        action.descriptions.each { |text| @out.puts "  ; #{text}" }
        write_action_legs(action)
        @out.puts '  Equity:FIXME' unless action.balanced?
        @out.puts
      end

      # Removals first: they read as the "before" side, and leaving the cost open
      # lets the account's booking method pick the lots being rebased.
      def write_action_legs(action)
        action.removed_legs.each { |leg| write_units(leg.symbol, leg.quantity, '{}') }
        action.added_legs.each do |leg|
          write_units(leg.symbol, leg.quantity, "{{#{money(leg.total)} #{@currency}}}")
        end
      end

      # Shares removed with nothing added cannot balance on their own — a delisting
      # paid out in cash, say. Flag it and leave an equity plug rather than emit a
      # file beancount will refuse to load.
      def write_action_header(entry, action)
        return write_header(entry, action.narration) if action.balanced?

        write_header(entry, "FIXME unbalanced corporate action: #{action.narration}",
                     flag: '!')
      end

      def write_security_transfer(group)
        write_header(group.first, group.first.description || 'ACATS transfer')
        group.each { |entry| write_units(entry.symbol, entry.quantity, transfer_cost(entry)) }
        @out.puts "  #{opening_account}"
        @out.puts
      end

      # Shares arriving carry the cost basis the statement reports. Shares leaving
      # are a reduction: asking for a lot at a given cost would only find one by
      # luck, so the cost stays open for the account's booking method.
      def transfer_cost(entry)
        return '{}' if entry.quantity.negative?

        "{#{money(entry.price)} #{@currency}}"
      end

      def write_cash_transfer(group)
        entry = group.first
        write_header(entry, entry.description || 'ACATS transfer')
        write_posting(cash_account, entry.amount)
        @out.puts "  #{opening_account}"
        @out.puts
      end

      # Alpaca reports the gross dividend and the tax withheld at source as separate
      # rows, and reverses a mis-booked one by repeating it with the opposite sign.
      # Both postings are therefore explicit and sign-driven: a reversal reverses.
      def write_dividend(group)
        entry = group.first
        write_two_sided(entry, labelled('Dividend', entry),
                        @targets.dividend || 'Income:FIXME')
      end

      def write_withholding(group)
        entry = group.first
        write_two_sided(entry, labelled('Withholding', entry),
                        @targets.withholding || 'Expenses:FIXME')
      end

      def write_interest(group)
        entry = group.first
        write_two_sided(entry, 'Cash Interest', @targets.interest || 'Income:FIXME')
      end

      def write_fee(group)
        entry = group.first
        write_two_sided(entry, entry.description || 'Fee',
                        @targets.fees || 'Expenses:FIXME')
      end

      def write_two_sided(entry, narration, account)
        write_header(entry, narration)
        write_posting(cash_account, entry.amount)
        write_posting(account, -entry.amount)
        @out.puts
      end

      def labelled(prefix, entry)
        entry.symbol ? "#{prefix} #{entry.symbol}" : prefix
      end

      # The counterpart of a journal entry is not knowable from the statement — the
      # description is either an opaque UUID or free text. Expenses:FIXME with a `*`
      # flag is exactly what `frijolero detail` rewrites from a rules file, so these
      # are left for that pass rather than guessed at here.
      def write_journal_entry(group)
        entry = group.first
        write_header(entry, "Journal Entry: #{entry.description}")
        write_posting(cash_account, entry.amount)
        @out.puts '  Expenses:FIXME'
        @out.puts
      end

      def skip_sweep(_group); end

      def write_unclassified(entry)
        write_header(entry, "FIXME unclassified entry: #{entry.entry_type}", flag: '!')
        write_posting(cash_account, entry.amount)
        @out.puts '  Equity:FIXME'
        @out.puts
      end

      # --- account lifecycle --------------------------------------------------

      # Dated at period start rather than at the movement that created the position:
      # an `open` only has to precede the account's first posting, and period start
      # is always safe without having to find that posting.
      #
      # Only commodity accounts are managed here. Cash, income, expense and equity
      # accounts belong in the ledger's own account_opens file — they outlive any
      # single statement.
      def write_opens(positions)
        return if @period_start.nil?

        symbols = positions.opened
        return if symbols.empty?

        symbols.each do |symbol|
          @out.puts "#{@period_start} open #{@account}:#{symbol} #{symbol} #{BOOKING}"
        end
        @out.puts
      end

      # Dated with the balance assertions, one day past the period, so the close
      # falls after every posting it covers.
      #
      # Known limitation: beancount refuses to reopen a closed account, so a position
      # exited in one month and re-entered in a later one produces a colliding
      # open/close pair across two files. It fails loudly at bean-check
      # ("Account ... is already open" plus "Posting to inactive account") and the fix
      # is to delete the earlier `close` and the later `open`. Nothing here can detect
      # it, because a converter only ever sees one month.
      def write_closes(positions)
        return if period_end.nil?

        symbols = positions.closed
        return if symbols.empty?

        @out.puts
        symbols.each { |symbol| @out.puts "#{assertion_date} close #{@account}:#{symbol}" }
      end

      # --- period-end directives ----------------------------------------------

      def write_price_declarations
        return if period_end.nil?

        @holdings.each do |holding|
          symbol = holding['symbol']
          price = holding['market_price']
          next if symbol.nil? || price.nil?

          @out.puts "#{period_end} price #{symbol}  #{price} #{@currency}"
        end
        @out.puts
      end

      # A `balance` directive asserts the balance at the START of its date, so the
      # closing figures are dated the day after the period ends — dating them at
      # period end would exclude any movement falling on the last day.
      #
      # Every holding is asserted, not just cash: the statement reports exact closing
      # share counts, so beancount can police share drift directly. A position exited
      # during the month drops out of the Holdings table, so it cannot be asserted to
      # zero — that gap is the one thing this does not catch.
      def write_balances
        return if period_end.nil?

        write_cash_balance
        @holdings.each do |holding|
          symbol = holding['symbol']
          next if symbol.nil? || holding['quantity'].nil?

          @out.puts "#{assertion_date} balance #{@account}:#{symbol}  " \
                    "#{number(holding['quantity'])} #{symbol}"
        end
      end

      def write_cash_balance
        closing = @cash_summary['ending_value'] || @cash_holding['market_value']
        return if closing.nil?

        @out.puts "#{assertion_date} balance #{cash_account}  #{grouped(closing)} #{@currency}"
      end

      def assertion_date
        (Date.parse(period_end) + 1).to_s
      end

      # --- file header --------------------------------------------------------

      # Restates the statement's own reconciliation so a later reader can check the
      # ledger against the source without opening the PDF.
      def write_file_header(stream)
        @out.puts "; Alpaca statement #{@period_start}..#{period_end} (#{@provider})"
        @out.puts "; Cash: #{cash_summary_line}"
        @out.puts "; Realized gain/loss this period: #{realized_line}"
        write_sweep_note(stream.count { |entry| entry.entry_type == SWEEP })
        @out.puts
      end

      def cash_summary_line
        summary = @cash_summary
        "#{money(summary['beginning_balance'])} + #{money(summary['addition'])} " \
          "- #{money(summary['subtraction'])} + #{money(summary['trade_transaction'])} " \
          "+ #{money(summary['cost_and_fees'])} = #{money(summary['ending_value'])}"
      end

      def realized_line
        short = (@realized['short_term'] || {})['net']
        long = (@realized['long_term'] || {})['net']
        "short #{money(short)}, long #{money(long)}"
      end

      def write_sweep_note(count)
        return if count.zero?

        @out.puts "; #{count} #{SWEEP} rows ignored (internal transfers)"
      end

      # --- primitives ---------------------------------------------------------

      def cash_account
        "#{@account}:Cash"
      end

      def opening_account
        @targets.opening || DEFAULT_OPENING
      end

      def write_units(symbol, quantity, cost)
        @out.puts "  #{@account}:#{symbol}  #{number(quantity)} #{symbol} #{cost}"
      end

      def write_commission(entry)
        return unless entry.commission.positive?

        write_posting(@targets.fees || 'Expenses:FIXME', entry.commission)
      end

      def write_posting(account, amount)
        @out.puts "  #{account}  #{money(amount)} #{@currency}"
      end

      # `Beancount` alone would resolve to Converters::Beancount, the default
      # converter class, rather than the string-literal helpers.
      def write_header(entry, narration, flag: '*')
        quoted = ::Frijolero::Beancount::Quoting.escape(narration)
        @out.puts %(#{entry.date} #{flag} "#{PAYEE}" "#{quoted}")
      end
    end
  end
end

require_relative 'plata/entry'
require_relative 'plata/corporate_action'
require_relative 'plata/positions'
