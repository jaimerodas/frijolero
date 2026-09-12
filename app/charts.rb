# frozen_string_literal: true

module Frijolero
  # The chart block of the reports. Ruby embeds the rows the page already has
  # as JSON; public/charts.js aggregates and draws them with d3. Reopens App.
  class App
    # The menu of the journal of one account, in order. A report gets its own list.
    CHARTS = { 'history' => 'Histograma', 'accounts' => 'Subcuentas', 'payees' => 'Contrapartes' }.freeze

    helpers do
      # Which charts the menu offers, or nil when there is no menu (no account, no
      # rows). A treemap needs at least two groups to split on: the first segment
      # under the account (postings on the account itself are one group), or the payee.
      def chart_options(rows, account)
        return if account.empty? || rows.empty?

        { 'history' => true, 'accounts' => chart_children(rows, account).size >= 2,
          'payees' => rows.map { |tx| tx[:payee].to_s }.uniq.size >= 2 }
      end

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

      def chart_postings(txn, sign)
        txn[:postings].select { |p| p[:matched] }.flat_map do |p|
          p[:amount].map do |currency, n|
            { date: txn[:date].iso8601, currency: currency, amount: (n * sign).to_f,
              account: p[:account], payee: txn[:payee] }
          end
        end
      end
    end
  end
end
