# frozen_string_literal: true

require 'test_helper'
require 'rack/test'

class ReportsPageTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  class FakeReports
    attr_reader :calls
    attr_accessor :error

    def initialize
      @calls = []
    end

    def first_date
      Date.new(2024, 12, 1)
    end

    def income(from, to, mxn: true)
      @calls << [:income, from, to, mxn]
      raise Frijolero::Reports::Error, error if error

      { 'Income:Salary' => { 'MXN' => BigDecimal('-1500') },
        'Expenses:Food:Tacos' => { 'MXN' => BigDecimal('100.5') },
        'Expenses:Fees' => { 'USD' => BigDecimal('3') } }
    end

    def balance(at, mxn: true)
      @calls << [:balance, at, mxn]
      raise Frijolero::Reports::Error, error if error

      { 'Assets:Bank' => { 'MXN' => BigDecimal('1100') },
        'Liabilities:Card' => { 'MXN' => BigDecimal('-250') },
        'Equity:Opening-Balances' => { 'MXN' => BigDecimal('-1000') },
        Frijolero::Reports::EARNINGS => { 'MXN' => BigDecimal('150') } }
    end

    def journal(prefix, from, to, mxn: true, text: nil)
      @calls << [:journal, prefix, from, to, mxn, text]
      raise Frijolero::Reports::Error, error if error

      txns = JOURNAL.map { |tx| tx.merge(postings: postings_for(tx, prefix)) }
      prefix.empty? ? txns : txns.select { |tx| tx[:postings].last[:matched] }
    end

    # The contract: matched postings flagged and sorted last.
    def postings_for(txn, prefix)
      txn[:postings].map { |p| p.merge(matched: matched?(p, prefix)) }.sort_by { |p| p[:matched] ? 1 : 0 }
    end

    def matched?(posting, prefix)
      !prefix.empty? && (posting[:account] == prefix || posting[:account].start_with?("#{prefix}:"))
    end

    JOURNAL = [
      { date: Date.new(2026, 7, 5), flag: '*', payee: 'AMAZON', narration: 'compra',
        file: '/data/ledger/accounts/AMEX/AMEX 2607.beancount',
        postings: [{ account: 'Liabilities:AMEX', amount: { 'MXN' => BigDecimal('-150.00') } },
                   { account: 'Expenses:Compras', amount: { 'MXN' => BigDecimal('150.00') } }] },
      { date: Date.new(2026, 7, 20), flag: '!', payee: nil, narration: 'Nómina',
        file: '/data/ledger/transactions.beancount',
        postings: [{ account: 'Income:Salary', amount: { 'MXN' => BigDecimal('-30000.00') } },
                   { account: 'Assets:BBVA', amount: { 'MXN' => BigDecimal('25000.00') } },
                   { account: 'Expenses:Taxes', amount: { 'MXN' => BigDecimal('5000.00') } }] }
    ].freeze
  end

  class FakeRepo
    attr_accessor :pulls, :error

    def initialize
      @pulls = 0
    end

    def head
      { date: '2026-09-09', subject: 'Payee American Express' }
    end

    def pull
      @pulls += 1
      raise Frijolero::LedgerRepo::Error, error if error
    end
  end

  def setup
    @reports = FakeReports.new
    @repo = FakeRepo.new
    Frijolero::App.reports = @reports
    Frijolero::App.repo = @repo
  end

  def teardown
    Frijolero::App.reports = nil
    Frijolero::App.repo = nil
  end

  def app
    Frijolero::App
  end

  def test_reports_redirects_to_the_income_statement
    get '/reports'

    assert_equal 302, last_response.status
    assert_equal '/reports/income', URI(last_response.location).path
  end

  def test_income_defaults_to_the_current_year
    get '/reports/income'

    today = Date.today
    assert_equal [[:income, Date.new(today.year, 1, 1), Date.new(today.year, 12, 31), true]], @reports.calls
    assert_includes last_response.body, '<h1>Estado de resultados</h1>'
    assert_includes last_response.body, %(<a href="/reports/balance?period=#{today.year}">Balance general</a>)
  end

  def test_income_takes_the_period_from_the_query
    get '/reports/income', period: '2025-T2'

    assert_equal [[:income, Date.new(2025, 4, 1), Date.new(2025, 6, 30), true]], @reports.calls
    assert_includes last_response.body, '<option value="2025-T2" selected>T2 2025</option>'
  end

  def test_a_bad_period_falls_back_to_the_current_year
    get '/reports/income', period: '2025-13'

    assert_equal Date.new(Date.today.year, 1, 1), @reports.calls.first[1]
  end

  def test_toolbar_switches_resolution_from_the_same_anchor_and_steps_periods
    get '/reports/income', period: '2025-05'
    body = last_response.body

    assert_includes body, '<a href="/reports/income?period=2025-T2">Trimestre</a>'
    assert_includes body, '<a href="/reports/income?period=2025">Año</a>'
    assert_includes body, '<a href="/reports/income?period=all">Todo</a>'
    assert_includes body, '<a href="/reports/income?period=2025-05" aria-current="true">Mes</a>'
    assert_includes body, '<a href="/reports/income?period=2025-04" aria-label="Anterior">'
    assert_includes body, '<a href="/reports/income?period=2025-06" aria-label="Siguiente">'
    assert_includes body, '<a href="/reports/balance?period=2025-05">Balance general</a>'
    assert_includes body, '<option value="2024-12">diciembre 2024</option>'
  end

  def test_reports_convert_to_mxn_by_default_and_show_the_toggle
    get '/reports/income', period: '2025-05'
    body = last_response.body

    assert_includes body, '<a href="/reports/income?period=2025-05" aria-current="true">MXN</a>'
    assert_includes body, '<a href="/reports/income?period=2025-05&amp;mxn=0">Por moneda</a>'
    refute_includes body, 'name="mxn"'
  end

  def test_mxn_0_keeps_the_original_currencies_and_carries_through_the_toolbar
    get '/reports/balance', period: '2025-05', mxn: '0'
    body = last_response.body

    assert_equal [[:balance, Date.new(2025, 5, 31), false]], @reports.calls
    assert_includes body, '<a href="/reports/balance?period=2025-05&amp;mxn=0" aria-current="true">Por moneda</a>'
    assert_includes body, '<a href="/reports/balance?period=2025-05">MXN</a>'
    assert_includes body, '<a href="/reports/income?period=2025-05&amp;mxn=0">Estado de resultados</a>'
    assert_includes body, '<a href="/reports/balance?period=2025-T2&amp;mxn=0">Trimestre</a>'
    assert_includes body, '<a href="/reports/balance?period=2025-04&amp;mxn=0" aria-label="Anterior">'
    assert_includes body, '<input type="hidden" name="mxn" value="0">'
  end

  def test_toolbar_greys_the_arrow_past_the_ledger_bounds
    get '/reports/income', period: 'all'

    refute_includes last_response.body, 'aria-label="Anterior"'
    assert_equal [[:income, Date.new(2024, 12, 1), Date.today, true]], @reports.calls
  end

  def test_income_shows_income_as_positive_and_the_net
    get '/reports/income'
    body = last_response.body

    assert_equal 200, last_response.status
    assert_includes body, '<title>Estado de resultados</title>'
    assert_includes body, 'style="--depth: 0">Salary</th>'
    assert_includes body, %(<a href="/journal?account=Income%3ASalary&amp;period=#{Date.today.year}">1,500.00</a>)
    assert_includes body, 'style="--depth: 1">Tacos</th>'
    assert_includes body, '1,399.50 MXN'
    assert_includes body, '-3.00 USD'
  end

  def test_income_folds_parents_and_hides_the_deeper_rows
    get '/reports/income'
    body = last_response.body

    assert_includes body, '<tr data-account="Expenses:Food" data-depth="1" class="total">'
    assert_includes body, '<button type="button" class="fold" aria-expanded="false">Food</button></th>'
    assert_includes body, '<tr data-account="Expenses:Food:Tacos" data-depth="2" hidden>'
    assert_includes body, '<tr data-account="Expenses:Fees" data-depth="1">'
    assert_includes body, '<script src="/reports.js" defer></script>'
  end

  def test_balance_defaults_to_today_and_shows_liabilities_positive
    get '/reports/balance'
    body = last_response.body

    assert_equal [[:balance, Date.today, true]], @reports.calls
    assert_includes body, '<title>Balance general</title>'
    assert_includes body, "al #{Date.today.iso8601}"
    assert_includes body, %(<a href="/journal?account=Liabilities%3ACard&amp;period=#{Date.today.year}">250.00</a>)
    assert_match %r{Utilidades-acumuladas</th>\s*<td class="amount" data-label="MXN">-150.00</td>}, body
    assert_includes body, '850.00 MXN'
  end

  def test_balance_is_a_snapshot_at_the_end_of_a_closed_period
    get '/reports/balance', period: '2025-T2'

    assert_equal [[:balance, Date.new(2025, 6, 30), true]], @reports.calls
    refute_includes last_response.body, 'al 2025'
  end

  def test_report_error_renders_the_message_with_502
    @reports.error = 'error: file not found'
    get '/reports/balance'

    assert_equal 502, last_response.status
    assert_includes last_response.body, '<p class="error" role="alert">error: file not found</p>'
  end

  def test_report_shows_the_ledger_head_and_a_pull_button
    get '/reports/balance'
    body = last_response.body

    assert_includes body, '<span class="note" title="Payee American Express">Datos actualizados al 2026-09-09</span>'
    assert_includes body, '<form method="post" action="/ledger/pull"'
    assert_includes body, '<input type="hidden" name="back" value="/reports/balance">'
  end

  def test_pull_returns_to_the_report_with_a_notice
    post '/ledger/pull', back: '/reports/balance'

    assert_equal 1, @repo.pulls
    assert_equal '/reports/balance?pull=ok', URI(last_response.location).request_uri

    get '/reports/balance', pull: 'ok'

    assert_includes last_response.body, '<p class="notice">Ledger actualizado.</p>'
  end

  def test_pull_failure_shows_the_git_error
    @repo.error = 'git pull: CONFLICT'
    post '/ledger/pull', back: '/evil'

    assert_equal '/reports/income?pull=git+pull%3A+CONFLICT', URI(last_response.location).request_uri

    get '/reports/income', pull: 'git pull: CONFLICT'

    assert_includes last_response.body, '<p class="error" role="alert">git pull: CONFLICT</p>'
  end

  def test_topbar_marks_reportes_current
    get '/reports/income'

    assert_includes last_response.body, '<a href="/reports" aria-current="page">Reportes</a>'
  end

  def test_journal_is_a_peer_in_the_reports_toolbar_and_is_the_title_on_its_own_page
    get '/reports/income'
    assert_match %r{<a href="/journal\?period=\d+">Diario</a>}, last_response.body

    get '/journal'
    assert_includes last_response.body, '<h1>Diario</h1>'
  end

  def test_journal_entry_is_payee_colon_narration_then_one_line_per_posting
    get '/journal'
    body = last_response.body

    assert_includes body, '<span class="line"><strong>AMAZON</strong>: compra</span>'
    assert_includes body, '<span class="line">Nómina <span class="flag">!</span></span>'
    assert_includes body, '<li><code>Assets:BBVA</code><data value="25000.0">25,000.00 MXN</data></li>'
    assert_includes body, '<li><code>Expenses:Taxes</code><data value="5000.0">5,000.00 MXN</data></li>'
  end

  def test_journal_postings_are_folded_behind_the_summary
    get '/journal', account: 'Income:Salary'

    assert_match(%r{<details>\s*<summary>.*Nómina.*</summary>\s*<ul class="postings">}m, last_response.body)
  end

  def test_journal_lists_the_matched_postings_last_and_muted_with_the_ledger_sign
    get '/journal', account: 'Income:Salary'

    assert_match(/Expenses:Taxes.*Income:Salary/m, last_response.body)
    assert_includes last_response.body,
                    '<li class="matched"><code>Income:Salary</code><data value="-30000.0">-30,000.00 MXN</data></li>'
  end

  def test_journal_headline_is_the_matched_sum_with_the_report_sign
    get '/journal', account: 'Income:Salary'

    assert_includes last_response.body, '<span class="sum"><data value="30000.0">30,000.00 MXN</data></span>'
  end

  def test_journal_without_an_account_has_no_headline_and_no_total
    get '/journal'
    body = last_response.body

    assert_includes body, '<p class="net">2 movimientos</p>'
    refute_includes body, 'class="sum"'
    refute_includes body, 'class="matched"'
  end

  def test_journal_filter_does_not_follow_the_links_to_the_reports
    get '/journal?account=Income:Dividends&period=2025-05&q=x'

    assert_includes last_response.body, '<a href="/reports/balance?period=2025-05">Balance general</a>'
  end

  def test_report_amount_links_ignore_a_stray_account_param
    get '/reports/income?period=2025-05&account=Income:Dividends'

    assert_includes last_response.body, '<a href="/journal?account=Expenses%3AFood&amp;period=2025-05">100.50</a>'
  end

  def test_journal_currency_tabs_keep_the_filter
    get '/journal?account=Expenses:Food&period=2025-05&q=uber'

    body = last_response.body
    filter = 'account=Expenses%3AFood&amp;q=uber'
    assert_includes body, %(<a href="/journal?period=2025-05&amp;#{filter}" aria-current="true">MXN</a>)
    assert_includes body, %(<a href="/journal?period=2025-05&amp;mxn=0&amp;#{filter}">Por moneda</a>)
  end

  def test_journal_shows_the_movement_count_and_total_per_currency
    get '/journal', account: 'Expenses'

    assert_includes last_response.body, '2 movimientos<data value="5150.0">5,150.00 MXN</data>'
  end

  def test_journal_toolbar_links_carry_the_account_and_the_search_text
    get '/journal', account: 'Expenses:Compras', q: 'uber', period: '2026-07'
    body = last_response.body

    assert_includes body, '<a href="/journal?period=2026&amp;account=Expenses%3ACompras&amp;q=uber">Año</a>'
    assert_includes body,
                    '<a href="/journal?period=2026-06&amp;account=Expenses%3ACompras&amp;q=uber" aria-label="Anterior">'
  end

  def test_journal_date_links_to_the_statement_only_for_a_statement_file
    get '/journal'
    body = last_response.body

    assert_includes body, '<time datetime="2026-07-05"><a href="/statements/AMEX/2607">2026-07-05</a></time>'
    assert_includes body, '<time datetime="2026-07-20">2026-07-20</time>'
  end

  def test_journal_calls_the_query_with_the_account
    from = Date.new(Date.today.year, 1, 1)
    to = Date.new(Date.today.year, 12, 31)
    get '/journal', account: 'Expenses:Food'

    assert_equal [:journal, 'Expenses:Food', from, to, true, nil], @reports.calls.last
  end

  def test_journal_calls_the_query_with_the_search_text
    get '/journal', q: 'uber'

    assert_equal 'uber', @reports.calls.last[5]
  end

  def test_journal_calls_the_query_with_the_currency_choice
    get '/journal', mxn: '0'

    assert_equal false, @reports.calls.last[4]
  end

  def test_an_account_with_a_quote_or_a_space_is_rejected_before_the_query_runs
    get '/journal', account: "It's"
    assert_equal 404, last_response.status

    get '/journal', account: 'Expenses Food'
    assert_equal 404, last_response.status

    assert_empty @reports.calls
  end

  def test_journal_error_renders_the_message_with_502
    @reports.error = 'error: rledger salió con 1'
    get '/journal'

    assert_equal 502, last_response.status
    assert_includes last_response.body, '<p class="error" role="alert">error: rledger salió con 1</p>'
  end

  def test_income_amount_cells_link_to_the_journal_and_leave_empty_cells_plain
    get '/reports/income', period: '2025-05'
    body = last_response.body

    assert_includes body, '<a href="/journal?account=Expenses%3AFood%3ATacos&amp;period=2025-05">100.50</a>'
    assert_match %r{Fees</th>\s*<td class="amount" data-label="MXN"></td>}, body
    assert_includes body, '<a href="/journal?account=Expenses%3AFees&amp;period=2025-05">3.00</a>'
  end

  def test_income_total_links_to_the_root_account
    get '/reports/income', period: '2025-05', mxn: '0'
    body = last_response.body

    assert_includes body, '<a href="/journal?account=Expenses&amp;period=2025-05&amp;mxn=0">100.50</a>'
  end

  def test_balance_earnings_row_has_no_link
    get '/reports/balance'

    assert_match %r{Utilidades-acumuladas</th>\s*<td class="amount" data-label="MXN">-150\.00</td>}, last_response.body
  end
end
