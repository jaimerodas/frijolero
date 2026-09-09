# frozen_string_literal: true

require 'test_helper'
require 'date'

class ReportsTest < Minitest::Test
  include TestHelpers

  Reports = Frijolero::Reports

  def with_rledger(command, &)
    Dir.mktmpdir do |dir|
      script = File.join(dir, 'rledger')
      File.write(script, "#!/bin/sh\n#{command}\n")
      File.chmod(0o755, script)
      previous = ENV.fetch('RLEDGER', nil)
      ENV['RLEDGER'] = script
      with_ledger_dir(&)
    ensure
      previous ? ENV['RLEDGER'] = previous : ENV.delete('RLEDGER')
    end
  end

  def test_query_parses_rows_into_amounts_by_currency
    rows = with_rledger("cat #{fixture_path('report/rows.json')}") { Reports.query('SELECT account') }

    assert_equal({ 'MXN' => BigDecimal('261992.28') }, rows['Assets:BBVA'])
    assert_equal BigDecimal('-74655.50'), rows['Equity:Opening-Balances']['USD']
  end

  def test_first_date_reads_the_scalar_row_in_either_shape
    with_rledger(%(echo '{"rows": [{"first": "2024-12-01"}]}')) do
      assert_equal Date.new(2024, 12, 1), Reports.first_date
    end
    with_rledger(%(echo '{"rows": [["2024-12-01"]]}')) { assert_equal Date.new(2024, 12, 1), Reports.first_date }
  end

  def test_first_date_is_today_on_a_ledger_with_no_transactions
    with_rledger(%(echo '{"rows": [[""]]}')) { assert_equal Date.today, Reports.first_date }
    with_rledger(%(echo '{"rows": []}')) { assert_equal Date.today, Reports.first_date }
  end

  def test_query_raises_with_stderr_when_rledger_fails
    error = assert_raises(Reports::Error) do
      with_rledger('echo "error: file not found" >&2; exit 1') { Reports.query('SELECT account') }
    end

    assert_equal 'error: file not found', error.message
  end

  def test_query_raises_when_rledger_is_missing
    previous = ENV.fetch('RLEDGER', nil)
    ENV['RLEDGER'] = '/nonexistent/rledger'
    with_ledger_dir { assert_raises(Reports::Error) { Reports.query('SELECT account') } }
  ensure
    previous ? ENV['RLEDGER'] = previous : ENV.delete('RLEDGER')
  end

  def test_income_queries_the_interval_and_only_income_and_expenses
    seen = nil
    Reports.stub(:query, lambda { |bql|
      seen = bql
      {}
    }) { Reports.income(Date.new(2026, 1, 1), Date.new(2026, 9, 9)) }

    assert_includes seen, "SUM(CONVERT(position, 'MXN', 2026-09-09)) AS total"
    assert_includes seen, 'date >= 2026-01-01 AND date <= 2026-09-09'
    assert_includes seen, "account ~ '^(Income|Expenses)'"
  end

  def test_income_keeps_the_original_currencies_when_asked
    seen = nil
    Reports.stub(:query, lambda { |bql|
      seen = bql
      {}
    }) { Reports.income(Date.new(2026, 1, 1), Date.new(2026, 9, 9), mxn: false) }

    assert_includes seen, 'SUM(position) AS total'
    refute_includes seen, 'CONVERT'
  end

  def test_balance_values_on_the_date_and_folds_earnings_into_equity
    rows = {
      'Assets:Bank' => { 'MXN' => BigDecimal('1100') },
      'Income:Salary' => { 'MXN' => BigDecimal('-500') },
      'Expenses:Food' => { 'MXN' => BigDecimal('100'), 'USD' => BigDecimal('3') }
    }
    seen = nil
    sheet = Reports.stub(:query, lambda { |bql|
      seen = bql
      rows
    }) { Reports.balance(Date.new(2024, 4, 30), mxn: false) }

    assert_includes seen, 'VALUE(SUM(position), 2024-04-30)'
    assert_includes seen, 'date <= 2024-04-30'
    assert_equal({ 'MXN' => BigDecimal('1100') }, sheet['Assets:Bank'])
    assert_equal({ 'MXN' => BigDecimal('400'), 'USD' => BigDecimal('-3') }, sheet[Reports::EARNINGS])
    refute sheet.key?('Income:Salary')
  end

  def test_balance_converts_to_mxn_at_the_date
    seen = nil
    Reports.stub(:query, lambda { |bql|
      seen = bql
      {}
    }) { Reports.balance(Date.new(2024, 4, 30)) }

    assert_includes seen, "SUM(CONVERT(position, 'MXN', 2024-04-30)) AS total"
    assert_includes seen, 'date <= 2024-04-30'
  end

  def test_tree_adds_parents_with_subtotals_in_tree_order
    rows = Reports.tree(
      'Expenses:Food:Tacos' => { 'MXN' => BigDecimal('10') },
      'Expenses:Fees' => { 'MXN' => BigDecimal('1'), 'USD' => BigDecimal('2') },
      'Expenses:Fees:Legal' => { 'MXN' => BigDecimal('5') },
      'Expenses:Fees-Extra' => { 'MXN' => BigDecimal('7') }
    )

    assert_equal(%w[Expenses Expenses:Fees Expenses:Fees:Legal Expenses:Fees-Extra Expenses:Food Expenses:Food:Tacos],
                 rows.map { |r| r[:name] })
    assert_equal({ 'MXN' => BigDecimal('23'), 'USD' => BigDecimal('2') }, rows[0][:amounts])
    assert_equal({ 'MXN' => BigDecimal('6'), 'USD' => BigDecimal('2') }, rows[1][:amounts])
    assert_equal([0, 1, 2, 1, 1, 2], rows.map { |r| r[:depth] })
    assert_equal([true, true, false, false, true, false], rows.map { |r| r[:total] })
  end

  def test_tree_leaves_out_accounts_at_zero
    rows = Reports.tree('Assets:Prius' => { 'MXN' => BigDecimal('0') }, 'Assets:Bank' => { 'MXN' => BigDecimal('5') })

    assert_equal(%w[Assets Assets:Bank], rows.map { |r| r[:name] })
  end

  # The real binary on a tiny ledger: FIFO lot reduction, a realized gain and a
  # market value from a price directive. Skipped where rustledger is not installed.
  def test_rledger_books_fifo_and_values_at_the_price
    skip 'rledger not installed' unless system(Frijolero::Config.rledger, '--version', out: File::NULL, err: File::NULL)

    with_ledger_dir do |dir|
      FileUtils.cp(fixture_path('report/ledger.beancount'), File.join(dir, 'moneys.beancount'))
      income = Reports.income(Date.new(2024, 1, 1), Date.new(2024, 12, 31), mxn: false)
      sheet = Reports.balance(Date.new(2024, 4, 30), mxn: false)

      assert_equal Date.new(2024, 1, 1), Reports.first_date
      assert_equal BigDecimal('-100'), income['Income:Gains']['MXN']
      assert_equal BigDecimal('-500'), income['Income:Salary']['MXN']
      assert_equal({ 'USD' => BigDecimal('-20') }, income['Income:Dollars'])
      assert_equal BigDecimal('750'), sheet['Assets:Stock']['MXN']
      assert_equal BigDecimal('1100'), sheet['Assets:Bank']['MXN']
      assert_equal({ 'USD' => BigDecimal('20') }, sheet['Assets:Dollars'])
      assert_equal BigDecimal('500'), sheet[Reports::EARNINGS]['MXN']
    end
  end

  # USD at the closing rate of the period (the latest price on or before it),
  # the priced stock at market, and the ticker with no price left as it is.
  def test_rledger_converts_to_mxn_at_the_closing_rate
    skip 'rledger not installed' unless system(Frijolero::Config.rledger, '--version', out: File::NULL, err: File::NULL)

    with_ledger_dir do |dir|
      FileUtils.cp(fixture_path('report/ledger.beancount'), File.join(dir, 'moneys.beancount'))
      income = Reports.income(Date.new(2024, 1, 1), Date.new(2024, 6, 30))
      sheet = Reports.balance(Date.new(2024, 4, 30))

      assert_equal({ 'MXN' => BigDecimal('-360') }, income['Income:Dollars'])
      assert_equal({ 'MXN' => BigDecimal('340') }, sheet['Assets:Dollars'])
      assert_equal({ 'MXN' => BigDecimal('750') }, sheet['Assets:Stock'])
      assert_equal({ 'NOPRICE' => BigDecimal('3') }, sheet['Assets:Unpriced'])
    end
  end
end
