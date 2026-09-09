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

    def income(from, to)
      @calls << [:income, from, to]
      raise Frijolero::Reports::Error, error if error

      { 'Income:Salary' => { 'MXN' => BigDecimal('-1500') },
        'Expenses:Food:Tacos' => { 'MXN' => BigDecimal('100.5') },
        'Expenses:Fees' => { 'USD' => BigDecimal('3') } }
    end

    def balance(at)
      @calls << [:balance, at]
      raise Frijolero::Reports::Error, error if error

      { 'Assets:Bank' => { 'MXN' => BigDecimal('1100') },
        'Liabilities:Card' => { 'MXN' => BigDecimal('-250') },
        'Equity:Opening-Balances' => { 'MXN' => BigDecimal('-1000') },
        Frijolero::Reports::EARNINGS => { 'MXN' => BigDecimal('150') } }
    end
  end

  def setup
    @reports = FakeReports.new
    Frijolero::App.reports = @reports
  end

  def teardown
    Frijolero::App.reports = nil
  end

  def app
    Frijolero::App
  end

  def test_reports_redirects_to_the_income_statement
    get '/reports'

    assert_equal 302, last_response.status
    assert_equal '/reports/income', URI(last_response.location).path
  end

  def test_income_defaults_to_the_year_to_date
    get '/reports/income'

    today = Date.today
    assert_equal [[:income, Date.new(today.year, 1, 1), today]], @reports.calls
  end

  def test_income_takes_the_range_from_the_query_and_ignores_bad_dates
    get '/reports/income', from: '2025-03-01', to: '2025-13-40'

    assert_equal Date.new(2025, 3, 1), @reports.calls.first[1]
    assert_equal Date.today, @reports.calls.first[2]
    assert_includes last_response.body, 'value="2025-03-01"'
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

    assert_equal [[:balance, Date.today]], @reports.calls
    assert_includes body, '<title>Balance general</title>'
    assert_match %r{Card</th>\s*<td class="amount" data-label="MXN">250.00</td>}, body
    assert_match %r{Utilidades-acumuladas</th>\s*<td class="amount" data-label="MXN">-150.00</td>}, body
    assert_includes body, '850.00 MXN'
  end

  def test_balance_takes_the_date_from_the_query
    get '/reports/balance', at: '2025-06-30'

    assert_equal Date.new(2025, 6, 30), @reports.calls.first[1]
  end

  def test_report_error_renders_the_message_with_502
    @reports.error = 'error: file not found'
    get '/reports/balance'

    assert_equal 502, last_response.status
    assert_includes last_response.body, '<p class="error" role="alert">error: file not found</p>'
  end

  def test_topbar_marks_reportes_current
    get '/reports/income'

    assert_includes last_response.body, '<a href="/reports" aria-current="page">Reportes</a>'
    assert_includes last_response.body,
                    '<a class="button" href="/reports/income" aria-current="page">Estado de resultados</a>'
  end
end
