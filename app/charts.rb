# frozen_string_literal: true

module Frijolero
  # The chart block of the reports. Ruby embeds the rows the page already has
  # as JSON; public/charts.js aggregates and draws them with d3. Reopens App.
  class App
    helpers do
      # The first chart lives on the journal of one account; the view shows the
      # toggle only there. A report gets its own chart name when it has one.
      def chart?
        params[:chart] == 'history' && !params[:account].to_s.empty?
      end

      # `chart=<name>` for the toolbar links, nil to drop it. The toggle passes
      # nil to turn the chart off.
      def chart_param(name)
        "chart=#{Rack::Utils.escape(name)}" unless name.to_s.empty?
      end

      # What charts.js draws: the period as drawn (a running one ends today) and
      # the matched postings, one per currency amount, already in the report sign.
      def chart_data(rows, period, today, sign)
        { period: { from: period.from.iso8601, to: [period.to, today].min.iso8601, resolution: period.resolution },
          postings: rows.flat_map { |tx| chart_postings(tx, sign) } }
      end

      def chart_postings(txn, sign)
        txn[:postings].select { |p| p[:matched] }.flat_map do |p|
          p[:amount].map { |currency, n| { date: txn[:date].iso8601, currency: currency, amount: (n * sign).to_f } }
        end
      end
    end
  end
end
