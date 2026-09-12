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
        Frijolero::Reports::EARNINGS => { 'MXN' => BigDecimal('-150') },
        Frijolero::Reports::UNREALIZED => { 'MXN' => BigDecimal('-40') },
        Frijolero::Reports::CONVERSIONS => { 'MXN' => BigDecimal('-10') } }
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

    # What the edit dialog's save will find. Set by the test; [] means clean.
    attr_accessor :check_errors

    def check
      @calls << [:check]
      check_errors || []
    end

    JOURNAL = [
      { date: Date.new(2026, 7, 5), flag: '*', payee: 'AMAZON', narration: 'compra',
        file: '/data/ledger/accounts/AMEX/AMEX 2607.beancount', line: 12,
        postings: [{ account: 'Liabilities:AMEX', amount: { 'MXN' => BigDecimal('-150.00') } },
                   { account: 'Expenses:Compras', amount: { 'MXN' => BigDecimal('150.00') } }] },
      { date: Date.new(2026, 7, 20), flag: '!', payee: nil, narration: 'Nómina',
        file: '/data/ledger/transactions.beancount', line: 3,
        postings: [{ account: 'Income:Salary', amount: { 'MXN' => BigDecimal('-30000.00') } },
                   { account: 'Assets:BBVA', amount: { 'MXN' => BigDecimal('25000.00') } },
                   { account: 'Expenses:Taxes', amount: { 'MXN' => BigDecimal('5000.00') } }] }
    ].freeze
  end

  class FakeRepo
    attr_accessor :pulls, :error, :messages

    def initialize
      @pulls = 0
      @messages = []
    end

    def head
      { date: '2026-09-09', subject: 'Payee American Express' }
    end

    def pull
      @pulls += 1
      raise Frijolero::LedgerRepo::Error, error if error
    end

    def commit_and_push(message)
      raise Frijolero::LedgerRepo::Error, error if error

      @messages << message
    end
  end

  # The journal fixtures name files under /data/ledger; the page only turns
  # those into relative paths, so the directory need not exist.
  def setup
    @reports = FakeReports.new
    @repo = FakeRepo.new
    Frijolero::App.reports = @reports
    Frijolero::App.repo = @repo
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = '/data/ledger'
  end

  def teardown
    Frijolero::App.reports = nil
    Frijolero::App.repo = nil
    @previous_ledger_dir ? ENV['LEDGER_DIR'] = @previous_ledger_dir : ENV.delete('LEDGER_DIR')
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
    assert_match %r{Utilidades-acumuladas</th>\s*<td class="amount" data-label="MXN">150.00</td>}, body
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
    assert_includes body, '<li><code>Assets:BBVA</code><data value="25000.0">25,000.00 MXN</data></li>'.sub(
      'Assets:BBVA', '<a href="/journal?account=Assets&amp;period=2026">Assets</a>:<wbr>' \
                     '<a href="/journal?account=Assets%3ABBVA&amp;period=2026">BBVA</a>'
    )
    assert_includes body, '5,000.00 MXN'
  end

  def test_each_segment_of_an_account_links_to_that_prefix_in_the_same_period
    get '/journal', account: 'Expenses:Taxes', period: '2026-07', mxn: '0'
    body = last_response.body

    assert_includes body, '<a href="/journal?account=Expenses&amp;period=2026-07&amp;mxn=0">Expenses</a>:<wbr>' \
                          '<a href="/journal?account=Expenses%3ATaxes&amp;period=2026-07&amp;mxn=0">Taxes</a>'
    assert_includes body,
                    '<h2 class="account"><a href="/journal?account=Expenses&amp;period=2026-07&amp;mxn=0">Expenses</a>:'
  end

  def test_journal_postings_are_folded_behind_the_summary
    get '/journal', account: 'Income:Salary'

    assert_match(%r{<details>\s*<summary>.*Nómina.*</summary>\s*<ul class="postings">}m, last_response.body)
  end

  def test_journal_lists_the_matched_postings_last_and_muted_with_the_ledger_sign
    get '/journal', account: 'Income:Salary'

    assert_match(/>Taxes<.*>Salary</m, last_response.body)
    assert_match(%r{class="matched"><code><a [^>]*>Income</a>:<wbr><a [^>]*>Salary</a></code><data value="-30000.0">},
                 last_response.body)
  end

  def test_journal_headline_is_the_matched_sum_with_the_report_sign
    get '/journal', account: 'Income:Salary'

    assert_includes last_response.body, '<span class="sum"><data value="30000.0">30,000.00 MXN</data></span>'
  end

  def test_journal_without_an_account_has_no_headline_and_no_total
    get '/journal'
    body = last_response.body

    assert_includes body, '<p class="net"><span class="count">2 movimientos</span></p>'
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

    assert_includes last_response.body,
                    '<span class="count">2 movimientos</span><data value="5150.0">5,150.00 MXN</data>'
  end

  def test_journal_total_of_zero_shows_zero_not_a_bare_currency
    rows = @reports.journal('Expenses', nil, nil)
    rows.first[:postings] = [{ account: 'Expenses:Compras', amount: { 'MXN' => BigDecimal('-150') }, matched: true },
                             { account: 'Expenses:Compras', amount: { 'MXN' => BigDecimal('150') }, matched: true }]
    @reports.define_singleton_method(:journal) { |*| [rows.first] }
    get '/journal', account: 'Expenses'

    assert_includes last_response.body, '<data value="0.0">0.00 MXN</data>'
  end

  def test_journal_count_has_a_thousands_separator
    rows = @reports.journal('Expenses', nil, nil)
    @reports.define_singleton_method(:journal) { |*| rows * 1000 }
    get '/journal', account: 'Expenses'

    assert_includes last_response.body, '<span class="count">2,000 movimientos</span>'
  end

  # Three Expenses rows: compra (2026-07-05, 150), Nómina (07-20, 5000) and a
  # third one whose date and amount order differently, chicle (07-25, 10).
  def journal_rows_with_chicle
    rows = @reports.journal('Expenses', nil, nil)
    rows << rows.first.merge(date: Date.new(2026, 7, 25), narration: 'chicle',
                             postings: [{ account: 'Expenses:Compras', amount: { 'MXN' => BigDecimal('10') },
                                          matched: true }])
    @reports.define_singleton_method(:journal) { |*| rows }
  end

  def order_of(body) = %w[compra Nómina chicle segunda].sort_by { |word| body.index(word) || body.size }

  def test_journal_lists_the_newest_first_and_keeps_the_ledger_order_within_a_day
    rows = @reports.journal('', nil, nil)
    rows << rows.first.merge(narration: 'segunda')
    @reports.define_singleton_method(:journal) { |*| rows }
    get '/journal'

    assert_equal %w[Nómina compra segunda chicle], order_of(last_response.body)
  end

  def test_journal_sort_date_asc_lists_the_oldest_first
    get '/journal', sort: 'date-asc'

    assert_equal %w[compra Nómina chicle segunda], order_of(last_response.body)
  end

  def test_journal_sorts_by_the_headline_sum_of_an_account
    journal_rows_with_chicle
    get '/journal', account: 'Expenses', sort: 'amount-desc'
    assert_equal %w[Nómina compra chicle segunda], order_of(last_response.body)

    get '/journal', account: 'Expenses', sort: 'amount-asc'
    assert_equal %w[chicle compra Nómina segunda], order_of(last_response.body)
  end

  def test_journal_unknown_sort_and_amount_sort_without_an_account_fall_back_to_newest_first
    journal_rows_with_chicle
    get '/journal', account: 'Expenses', sort: 'payee'
    assert_equal %w[chicle Nómina compra segunda], order_of(last_response.body)

    get '/journal', sort: 'amount-desc'
    assert_equal %w[chicle Nómina compra segunda], order_of(last_response.body)
    refute_includes last_response.body, 'amount-desc'
  end

  def test_journal_order_links_flip_the_current_key_and_mark_it
    get '/journal', account: 'Expenses', period: '2026'
    body = last_response.body
    assert_match(%r{</p>\s*<p class="order">.*</p>\s*<ol class="ledger">}m, body)
    assert_includes body, '<a href="/journal?period=2026&amp;account=Expenses&amp;sort=date-asc" ' \
                          'aria-current="true">Fecha ▾</a>'
    assert_includes body, '<a href="/journal?period=2026&amp;account=Expenses&amp;sort=amount-desc">Monto</a>'

    get '/journal', account: 'Expenses', period: '2026', sort: 'amount-asc'
    body = last_response.body
    assert_includes body, '<a href="/journal?period=2026&amp;account=Expenses">Fecha</a>'
    assert_includes body, '<a href="/journal?period=2026&amp;account=Expenses&amp;sort=amount-desc" ' \
                          'aria-current="true">Monto ▴</a>'
  end

  def test_journal_order_line_has_no_monto_without_an_account_and_is_absent_without_rows
    get '/journal', period: '2026', sort: 'date-asc'
    body = last_response.body
    assert_includes body, '<a href="/journal?period=2026" aria-current="true">Fecha ▴</a>'
    refute_includes body, 'Monto'

    @reports.define_singleton_method(:journal) { |*| [] }
    get '/journal', account: 'Expenses'
    refute_includes last_response.body, 'class="order"'
  end

  def test_journal_sort_rides_the_toolbar_links_and_the_forms_but_not_the_links_to_the_reports
    get '/journal', account: 'Expenses', q: 'uber', period: '2026-07', sort: 'date-asc'
    body = last_response.body

    filter = 'account=Expenses&amp;q=uber&amp;sort=date-asc'
    assert_includes body, %(<a href="/journal?period=2026&amp;#{filter}">Año</a>)
    assert_includes body, %(<a href="/journal?period=2026-07&amp;mxn=0&amp;#{filter}">Por moneda</a>)
    assert_includes body, %(<a href="/journal?period=2026-06&amp;#{filter}" aria-label="Anterior">)
    assert_includes body, '<a href="/reports/income?period=2026-07">Estado de resultados</a>'
    hidden = '<input type="hidden" name="sort" value="date-asc">'
    assert_match(%r{<form method="get" action="/journal" class="period">.*#{hidden}.*</form>}m, body)
    assert_match(%r{<form method="get" action="/journal" role="search">.*#{hidden}.*</form>}m, body)
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

    assert_includes body, '<time datetime="2026-07-05"><a href="/accounts/AMEX/2607">2026-07-05</a></time>'
    assert_includes body, '<time datetime="2026-07-20">2026-07-20</time>'
  end

  def test_journal_entries_carry_an_edit_button_with_the_relative_file_and_the_line
    get '/journal'
    body = last_response.body

    assert_includes body,
                    '<button type="button" class="edit" data-file="accounts/AMEX/AMEX 2607.beancount" data-line="12">'
    assert_includes body, '<button type="button" class="edit" data-file="transactions.beancount" data-line="3">'
    assert_match(/<dialog id="edit">.*<form method="dialog">.*<textarea id="edit-content" name="content"/m, body)
  end

  def test_chart_menu_sits_in_the_search_form_of_an_account
    get '/journal', account: 'Expenses', period: '2026'
    menu = '<select name="chart" aria-label="Gráficas"><option value="">Gráficas…</option>' \
           '<option value="history">Histograma</option><option value="accounts">Subcuentas</option>' \
           '<option value="payees">Contrapartes</option></select>'
    assert_match(%r{<form method="get" action="/journal" role="search">.*#{Regexp.escape(menu)}.*<input type="search"}m,
                 last_response.body)

    get '/journal', period: '2026'
    refute_includes last_response.body, 'Gráficas'

    get '/reports/income', account: 'Expenses', period: '2026'
    refute_includes last_response.body, 'Gráficas'
  end

  def test_chart_menu_disables_a_treemap_with_one_group_and_ignores_a_request_for_it
    get '/journal', account: 'Income:Salary', period: '2026', chart: 'accounts'
    body = last_response.body

    assert_includes body, '<option value="history">Histograma</option>' \
                          '<option value="accounts" disabled>Subcuentas</option>' \
                          '<option value="payees" disabled>Contrapartes</option>'
    refute_includes body, 'selected>Subcuentas'
    refute_includes body, 'd3.min.js'
    refute_includes body, 'chart-data'
  end

  def test_chart_block_follows_the_journal_head_and_needs_rows
    get '/journal', account: 'Income:Salary', period: '2026', chart: 'history'
    assert_match(%r{</header>\s*<section class="chart" aria-label="Gráfica">}, last_response.body)

    @reports.error = 'rledger: boom'
    get '/journal', account: 'Income:Salary', period: '2026', chart: 'history'
    refute_includes last_response.body, 'chart-data'
    refute_includes last_response.body, 'Gráficas'
  end

  def test_chart_embeds_the_matched_postings_in_the_report_sign_and_the_period_cut_at_today
    get '/journal', account: 'Income:Salary', period: '2026', chart: 'history'
    body = last_response.body

    assert_includes body, '<script src="/d3.min.js" defer></script><script src="/charts.js" defer></script>'
    assert_includes body, '<option value="history" selected>Histograma</option>'
    period = %({"from":"2026-01-01","to":"#{Date.today.iso8601}","resolution":"year"})
    assert_includes body, '<script type="application/json" id="chart-data">' \
                          "{\"chart\":\"history\",\"period\":#{period}," \
                          '"postings":[{"date":"2026-07-20","currency":"MXN","amount":30000.0,' \
                          '"account":"Income:Salary","payee":null}]}</script>'
  end

  def test_chart_period_ends_at_the_last_day_of_a_closed_period
    get '/journal', account: 'Expenses', period: '2026-07', chart: 'history'

    assert_includes last_response.body, '"period":{"from":"2026-07-01","to":"2026-07-31","resolution":"month"}'
  end

  def test_journal_without_the_chart_loads_no_script_and_no_data
    get '/journal', account: 'Expenses', period: '2026'
    body = last_response.body

    refute_includes body, 'd3.min.js'
    refute_includes body, 'charts.js'
    refute_includes body, 'chart-data'
  end

  def test_chart_rides_the_toolbar_links_and_the_forms_but_not_the_links_to_the_reports
    get '/journal', account: 'Expenses', q: 'uber', period: '2026-07', chart: 'history'
    body = last_response.body

    filter = 'account=Expenses&amp;q=uber&amp;chart=history'
    assert_includes body, %(<a href="/journal?period=2026&amp;#{filter}">Año</a>)
    assert_includes body, %(<a href="/journal?period=2026-07&amp;mxn=0&amp;#{filter}">Por moneda</a>)
    assert_includes body, '<a href="/reports/income?period=2026-07">Estado de resultados</a>'
    hidden = '<input type="hidden" name="chart" value="history">'
    assert_match(%r{<form method="get" action="/journal" class="period">.*#{hidden}.*</form>}m, body)
    assert_match(%r{<form method="get" action="/journal" role="search">.*<select name="chart".*</form>}m, body)
  end

  def test_journal_period_menu_keeps_the_account_and_the_search_text
    get '/journal', account: 'Expenses', q: 'uber', period: '2026-07'

    hidden = '<input type="hidden" name="account" value="Expenses">.*<input type="hidden" name="q" value="uber">'
    assert_match(%r{<form method="get" action="/journal" class="period">.*#{hidden}.*<select name="period"}m,
                 last_response.body)
  end

  STATEMENT = "2026-07-05 * \"AMAZON\" \"compra\"\n  Liabilities:AMEX  -150.00 MXN\n  Expenses:Compras\n\n" \
              "2026-07-06 * \"Uber\"\n  Liabilities:AMEX  -50.00 MXN\n  Expenses:Transporte\n"

  # The edit routes read and write a real file, so they get a ledger on disk.
  def with_statement
    with_ledger_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'accounts', 'AMEX'))
      path = File.join(dir, 'accounts', 'AMEX', 'AMEX 2607.beancount')
      File.write(path, STATEMENT)
      yield path
    end
  end

  def test_edit_answers_with_the_block_of_the_transaction_as_json
    with_statement do
      get '/edit', file: 'accounts/AMEX/AMEX 2607.beancount', line: 2

      assert_equal 200, last_response.status
      assert_includes last_response.content_type, 'application/json'
      assert_equal({ 'first' => 1, 'last' => 3, 'text' => STATEMENT.lines[0..2].join }, JSON.parse(last_response.body))
    end
  end

  def test_edit_is_404_outside_the_ledger_or_off_a_transaction
    with_statement do
      get '/edit', file: '../etc/passwd.beancount', line: 1
      assert_equal 404, last_response.status

      get '/edit', file: 'accounts/AMEX/AMEX 2607.beancount', line: 99
      assert_equal 404, last_response.status
    end
  end

  def test_saving_an_edit_writes_the_file_and_commits_with_the_transaction_in_the_subject
    with_statement do |path|
      original = STATEMENT.lines[0..2].join
      post '/edit', file: 'accounts/AMEX/AMEX 2607.beancount', line: 2, original: original,
                    content: original.sub('Compras', 'Casa')

      assert_equal 204, last_response.status
      assert_includes File.read(path), "  Expenses:Casa\n"
      assert_includes @reports.calls, [:check]
      assert_equal 'Edición AMEX 2607: 2026-07-05 AMAZON', @repo.messages.first.lines.first.chomp
    end
  end

  def test_an_edit_that_fails_the_check_is_422_with_the_errors_and_leaves_the_file
    with_statement do |path|
      @reports.check_errors = ['E1001 Account Expenses:Casa was never opened (accounts/AMEX/AMEX 2607.beancount:1)']
      original = STATEMENT.lines[0..2].join
      post '/edit', file: 'accounts/AMEX/AMEX 2607.beancount', line: 2, original: original,
                    content: original.sub('Compras', 'Casa')

      assert_equal 422, last_response.status
      assert_equal @reports.check_errors.first, last_response.body
      assert_equal STATEMENT, File.read(path)
      assert_empty @repo.messages
    end
  end

  def test_a_stale_edit_is_409
    with_statement do
      post '/edit', file: 'accounts/AMEX/AMEX 2607.beancount', line: 2, original: "2026-07-05 * \"other\"\n",
                    content: 'x'

      assert_equal 409, last_response.status
      assert_includes last_response.body, 'cambió'
    end
  end

  def test_a_failed_push_after_a_valid_edit_is_502_and_says_the_file_is_saved
    with_statement do |path|
      @repo.error = 'git push: rejected'
      original = STATEMENT.lines[0..2].join
      post '/edit', file: 'accounts/AMEX/AMEX 2607.beancount', line: 2, original: original,
                    content: original.sub('Compras', 'Casa')

      assert_equal 502, last_response.status
      assert_includes last_response.body, 'git push: rejected'
      assert_includes File.read(path), "  Expenses:Casa\n"
    end
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

  # The three synthetic rows are not accounts, so they have no journal to link to.
  def test_balance_synthetic_rows_show_flipped_and_have_no_link
    get '/reports/balance'
    body = last_response.body

    assert_match %r{Utilidades-acumuladas</th>\s*<td class="amount" data-label="MXN">150\.00</td>}, body
    assert_match %r{Ganancias-no-realizadas</th>\s*<td class="amount" data-label="MXN">40\.00</td>}, body
    assert_match %r{Conversiones</th>\s*<td class="amount" data-label="MXN">10\.00</td>}, body
  end
end
