# frozen_string_literal: true

require 'date'

module Frijolero
  # Estado de resultados, Balance general and Diario over the whole ledger. Reopens App.
  class App
    helpers do
      # Report figures, display only: no sign on positives. A table cell blanks a
      # zero; a `<data>` line next to its currency shows 0.00.
      def figure(amount) = amount.zero? ? '' : datum(amount)
      def datum(amount) = money(amount).delete_prefix('+')

      # The pull button returns to the report it sits on. Nothing else is honoured.
      def report_back
        params[:back] if %w[/reports/income /reports/balance /journal].include?(params[:back])
      end

      def ledger_head
        self.class.repo.head
      rescue LedgerRepo::Error
        nil
      end

      # /accounts/<Key>/<YYMM> for a row from `accounts/<Key>/<Key> YYMM.beancount`,
      # the layout Statement writes; nil for transactions.beancount (inline txns).
      def journal_statement_link(file)
        match = %r{accounts/([^/]+)/\1 (\d{4})\.beancount\z}.match(file.to_s)
        "/accounts/#{Rack::Utils.escape_path(match[1])}/#{match[2]}" if match
      end

      # Each segment of an account links to the journal of that prefix, same
      # period and currency: Expenses:Food:Coffee is three links, and a long name may
      # wrap after a colon. HTML, escaped here.
      def account_links(account, period)
        parts = account.split(':')
        parts.each_index.map do |i|
          href = "/journal?account=#{Rack::Utils.escape(parts[..i].join(':'))}&#{report_query(period, filter: false)}"
          %(<a href="#{Rack::Utils.escape_html(href)}">#{Rack::Utils.escape_html(parts[i])}</a>)
        end.join(':<wbr>')
      end

      # `key=value`, URL-escaped, or nil when the param is absent or blank.
      def query_param(key)
        "#{key}=#{Rack::Utils.escape(params[key])}" unless params[key].to_s.empty?
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

      # `mxn:` lets the currency tabs pick the other choice. The journal filter
      # travels only between journal pages: a report link, or a link from a
      # report, drops it, so a filter never leaks into another page's links.
      def report_query(period, mxn: mxn?, filter: request.path_info == '/journal', chart: params[:chart])
        parts = ["period=#{period.param}"]
        parts << 'mxn=0' unless mxn
        parts += [query_param(:account), query_param(:q), chart_param(chart)].compact if filter
        parts.join('&')
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

    # One row per posting, behind the report figures. `account` reaches the
    # query builder only after this check: the trust boundary for `?account=`.
    get '/journal' do
      account = params[:account].to_s
      halt 404 unless account.match?(/\A[A-Za-z0-9:-]*\z/)

      today = Date.today
      first = self.class.reports.first_date
      period = report_period(first, today)
      sign = account.start_with?('Income', 'Liabilities', 'Equity') ? -1 : 1
      begin
        rows = self.class.reports.journal(account, period.from, period.to, mxn: mxn?, text: params[:q])
        error = nil
      rescue Reports::Error => e
        status 502
        rows = []
        error = e.message
      end
      total = Hash.new(0)
      rows.each { |tx| tx[:postings].each { |p| p[:amount].each { |c, n| total[c] += n } if p[:matched] } }
      chart = chart? && chart_data(rows, period, today, sign)
      erb :journal, locals: { period: period, first: first, today: today, error: error, account: account,
                              rows: rows, sign: sign, total: total, chart: chart }
    end
  end
end
