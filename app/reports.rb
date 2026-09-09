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

      def report_date(value)
        Date.iso8601(value.to_s)
      rescue Date::Error
        nil
      end

      # Rows grouped by root account, plus the currencies seen. A Reports::Error
      # renders the same page with the message, like a B2 failure on an account page.
      def report_locals
        rows = Reports.tree(yield)
        { sections: rows.group_by { |row| row[:name][/\A[^:]+/] },
          currencies: rows.flat_map { |row| row[:amounts].keys }.uniq.sort, error: nil }
      rescue Reports::Error => e
        status 502
        { sections: {}, currencies: [], error: e.message }
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
      today = Date.today
      from = report_date(params[:from]) || Date.new(today.year, 1, 1)
      to = report_date(params[:to]) || today
      erb :report_income, locals: { from: from, to: to }.merge(report_locals { self.class.reports.income(from, to) })
    end

    get '/reports/balance' do
      at = report_date(params[:at]) || Date.today
      erb :report_balance, locals: { at: at }.merge(report_locals { self.class.reports.balance(at) })
    end
  end
end
