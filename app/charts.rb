# frozen_string_literal: true

module Frijolero
  # The chart block of the reports. Ruby embeds the rows the page already has
  # as JSON; public/charts.js aggregates and draws them with d3. Reopens App.
  class App
    # The menu of the journal of one account, in order. A report gets its own list.
    CHARTS = { 'history' => 'Histograma', 'balance' => 'Saldo', 'accounts' => 'Subcuentas',
               'payees' => 'Contrapartes' }.freeze
    # Each report's diagram, the third view after its two currency tabs.
    DIAGRAMS = { '/reports/income' => 'sankey', '/reports/balance' => 'icicle' }.freeze

    helpers do
      # Which charts the menu offers, or nil when there is no menu (no account, no
      # rows). A balance-sheet account gets the balance line instead of the histogram,
      # and not with a search text, because the opening of a filtered subset means
      # nothing. A treemap needs at least two groups to split on: the first segment
      # under the account (postings on the account itself are one group), or the payee.
      def chart_options(rows, account)
        return if account.empty? || rows.empty?

        sheet = sheet?(account)
        { 'history' => !sheet, 'balance' => sheet && !searching?,
          'accounts' => chart_children(rows, account).size >= 2,
          'payees' => rows.map { |tx| tx[:payee].to_s }.uniq.size >= 2 }
      end

      def searching? = !params[:q].to_s.strip.empty?
      def sheet?(account) = account.start_with?('Assets', 'Liabilities', 'Equity')

      def chart_children(rows, account)
        rows.flat_map { |tx| tx[:postings].select { |p| p[:matched] } }
            .map { |p| p[:account].delete_prefix(account).split(':')[1] }.uniq
      end
    end

    helpers do
      # The requested chart when the menu offers it; a disabled one counts as none.
      def chart_name(options)
        params[:chart] if options&.dig(params[:chart])
      end

      # `chart=<name>` for the toolbar links, nil to drop it.
      def chart_param(name)
        "chart=#{Rack::Utils.escape(name)}" unless name.to_s.empty?
      end

      # What charts.js draws: the chart, the period as drawn (a running one ends
      # today) and the matched postings, one per currency amount, already in the
      # report sign, with the account and the payee for the treemaps.
      def chart_data(rows, period, today, sign, name)
        { chart: name,
          period: { from: period.from.iso8601, to: [period.to, today].min.iso8601, resolution: period.resolution },
          postings: rows.flat_map { |tx| chart_postings(tx, sign) } }
      end

      # The balance line also gets the opening balance, in the same sign, so it
      # starts where the period does. Nothing for the other charts.
      def chart_opening(opening, sign)
        opening ? { opening: opening.transform_values { |n| (n * sign).to_f } } : {}
      end

      def chart_postings(txn, sign)
        txn[:postings].select { |p| p[:matched] }.flat_map do |p|
          p[:amount].map do |currency, n|
            { date: txn[:date].iso8601, currency: currency, amount: (n * sign).to_f,
              account: p[:account], payee: txn[:payee] }
          end
        end
      end
    end

    helpers do
      # The journal's running balance column, the balance line's twin: a balance-sheet account,
      # in date order, and not with a search text, for the same reason as the line.
      def running_balance?(account) = sheet?(account) && journal_sort.start_with?('date') && !searching?

      # The balance before the period, or nil when neither the balance line nor the
      # column shows: one query for both. Fills the column on the way.
      def journal_opening(index, account, period, chart, sign)
        running = running_balance?(account)
        return unless chart == 'balance' || running

        opening = self.class.reports.opening(account, period.from, period.to, mxn: mxn?)
        journal_running(index, opening, sign) if running
        opening
      end

      # `running` on every entry of the index, not just the page's, so a later page picks up
      # where the one before it ends: the opening plus each entry, oldest first, in the
      # report sign and in the currencies the entry moves.
      def journal_running(index, opening, sign)
        balance = opening.transform_values { |n| n * sign }
        (journal_sort == 'date-desc' ? index.reverse : index).each do |tx|
          tx[:running] = tx[:sum].to_h { |c, n| [c, balance[c] = balance.fetch(c, 0) + n] }
        end
      end
    end

    helpers do
      # The diagram of this report, or nil on any other page.
      def report_diagram = DIAGRAMS[request.path_info]

      # The report's own diagram: in MXN, when asked for.
      def diagram? = mxn? && !report_diagram.nil? && params[:chart] == report_diagram

      # What charts.js draws: the leaves of Income and Expenses with their MXN
      # amount in the report sign, sorted by account. It builds the tree itself,
      # so a negative net (a refund larger than the spend) can move to the other
      # side. A commodity with no price has no MXN and is left out. Nil when nothing.
      def sankey_data(flat, period)
        rows = flat.filter_map do |account, amounts|
          n = amounts['MXN']
          next if n.nil? || n.zero?

          { account: account, amount: (account.start_with?('Income') ? -n : n).to_f }
        end
        { chart: 'sankey', period: period.param, rows: rows.sort_by { |row| row[:account] } } unless rows.empty?
      end

      # The icicle of the balance sheet: the Assets accounts with their MXN market value,
      # sorted by account; charts.js builds the tree. A negative or unpriced asset has no
      # area and is left out, so a parent can exceed its row in the table. Nil when nothing.
      def icicle_data(flat, period)
        rows = flat.filter_map do |account, amounts|
          n = amounts['MXN']
          { account: account, amount: n.to_f } if account.start_with?('Assets:') && n&.positive?
        end
        { chart: 'icicle', period: period.param, rows: rows.sort_by { |row| row[:account] } } unless rows.empty?
      end
    end
  end
end
