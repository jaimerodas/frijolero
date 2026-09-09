# frozen_string_literal: true

require 'date'

module Frijolero
  # Estado de resultados and Balance general over the whole ledger. Reopens App.
  class App
    helpers do
      # Report figures: no sign on positives, blank for zero. Display only.
      def figure(amount)
        amount.zero? ? '' : money(amount).delete_prefix('+')
      end

      # The pull button returns to the report it sits on. Nothing else is honoured.
      def report_back
        params[:back] if %w[/reports/income /reports/balance].include?(params[:back])
      end

      def ledger_head
        self.class.repo.head
      rescue LedgerRepo::Error
        nil
      end
    end

    helpers do
      # `?period=` picks the span (see Period); anything else means the current year.
      # The block gets the period and returns the flat rows. A Reports::Error renders
      # the same page with the message, like a B2 failure on an account page.
      def report_locals
        today = Date.today
        first = self.class.reports.first_date
        period = report_period(first, today)
        { period: period, first: first, today: today, error: nil }.merge(report_sections(Reports.tree(yield(period))))
      rescue Reports::Error => e
        status 502
        { period: report_period(today, today), first: today, today: today, error: e.message }.merge(report_sections([]))
      end

      # Everything in MXN unless `?mxn=0`. The toolbar links carry the choice.
      def mxn?
        params[:mxn] != '0'
      end

      def report_query(period)
        mxn? ? "period=#{period.param}" : "period=#{period.param}&mxn=0"
      end

      def report_period(first, today)
        Period.parse(params[:period], first: first, today: today) || Period.of(today, :year)
      end

      def report_sections(rows)
        { sections: rows.group_by { |row| row[:name][/\A[^:]+/] },
          currencies: rows.flat_map { |row| row[:amounts].keys }.uniq.sort }
      end
    end

    get '/reports' do
      redirect '/reports/income'
    end

    # Production reads the droplet's clone, which only pulls at the start of a
    # job. This brings in what the laptop pushed. A conflict aborts and shows.
    post '/ledger/pull' do
      self.class.repo.pull
      redirect "#{report_back || '/reports/income'}?pull=ok", 303
    rescue LedgerRepo::Error => e
      redirect "#{report_back || '/reports/income'}?pull=#{Rack::Utils.escape(e.message)}", 303
    end

    get '/reports/income' do
      rows = report_locals { |period| self.class.reports.income(period.from, period.to, mxn: mxn?) }
      erb :report_income, locals: rows
    end

    # A snapshot at the end of the period, or today while it is still running.
    get '/reports/balance' do
      rows = report_locals { |period| self.class.reports.balance([period.to, Date.today].min, mxn: mxn?) }
      erb :report_balance, locals: rows
    end
  end
end
