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
    assert_match %r{style="--depth: 0">Salary</th>\s*<td class="amount" data-label="MXN">1,500.00</td>}, body
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
    assert_match %r{Card</th>\s*<td class="amount" data-label="MXN">250.00</td>}, body
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
end
