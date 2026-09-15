# frozen_string_literal: true

module Frijolero
  # The chart block of the reports. Ruby embeds the rows the page already has
  # as JSON; public/charts.js aggregates and draws them with d3. Reopens App.
  class App
    # The menu of the journal of one account, in order. A report gets its own list.
    CHARTS = { 'history' => 'Histograma', 'balance' => 'Saldo', 'accounts' => 'Subcuentas',
               'payees' => 'Contrapartes' }.freeze

    helpers do
      # Which charts the menu offers, or nil when there is no menu (no account, no
      # rows). A balance-sheet account gets the balance line instead of the histogram,
      # and not with a search text, because the opening of a filtered subset means
      # nothing. A treemap needs at least two groups to split on: the first segment
      # under the account (postings on the account itself are one group), or the payee.
      def chart_options(rows, account)
        return if account.empty? || rows.empty?

        sheet = account.start_with?('Assets', 'Liabilities', 'Equity')
        { 'history' => !sheet, 'balance' => sheet && !searching?,
          'accounts' => chart_children(rows, account).size >= 2,
          'payees' => rows.map { |tx| tx[:payee].to_s }.uniq.size >= 2 }
      end

      def searching? = !params[:q].to_s.strip.empty?

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
      # The Sankey of the income statement: on its page, in MXN, when asked for.
      def sankey?
        request.path_info == '/reports/income' && mxn? && params[:chart] == 'sankey'
      end

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
    end
  end
end
