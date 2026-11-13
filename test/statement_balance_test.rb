# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class StatementBalanceTest < Minitest::Test
  include TestHelpers

  AMEX = { 'beancount_account' => 'Liabilities:Amex', 'cutoff_day' => 3 }.freeze

  def setup
    Frijolero::Log.sink = StringIO.new
  end

  def teardown
    Frijolero::Log.sink = $stdout
  end

  # What a job leaves before the balance: the JSON and the converted file. Then the balance.
  # A Multi prints a list of closing balances.
  def statement(period, rows, closing, key: 'AMEX', config: AMEX)
    json = Frijolero::Config.statement_path(key, period, 'json')
    FileUtils.mkdir_p(File.dirname(json))
    File.write(json, JSON.generate('transactions' => rows,
                                   (closing.is_a?(Array) ? 'closing_balances' : 'closing_balance') => closing))
    Frijolero::Converters::Default.convert(input: json, account: config['beancount_account'], output: path(period, key),
                                           sources: config['accounts'] || {})
    Frijolero::StatementBalance.write(key, period, config)
  end

  def row(date, amount, **extra) = { 'date' => date, 'description' => 'X', 'amount' => amount, **extra }
  def path(period, key = 'AMEX') = Frijolero::Config.statement_path(key, period, 'beancount')
  def balances(period, key = 'AMEX') = File.readlines(path(period, key)).grep(/ balance /).map(&:chomp)

  # Beancount checks a balance before the rows of its day, so the PDF's balance loses the
  # statement's own rows of the closing day, each one written out.
  def test_the_line_goes_on_the_closing_day_without_the_own_rows_of_that_day
    with_ledger_dir do
      statement('2610', [row('2026-10-10', -1000), row('2026-11-03', -4.2)], -1004.2)

      assert_equal ['2026-11-03 balance Liabilities:Amex  -1,004.20 + 4.20 MXN'], balances('2610')
    end
  end

  # An Amazon charge that AMEX bills a month late, dated before the close it belongs to.
  def test_a_row_of_the_next_statement_dated_before_the_close_goes_into_that_line
    with_ledger_dir do
      statement('2609', [row('2026-09-10', -1000)], -1000)
      statement('2610', [row('2026-10-02', -349.86), row('2026-10-10', -100)], -1449.86)

      assert_equal ['2026-10-03 balance Liabilities:Amex  -1,000.00 - 349.86 MXN'], balances('2609')
    end
  end

  # Sobrescribir runs the next statement again: the line is written again, never twice.
  def test_processing_the_next_statement_again_keeps_one_line
    with_ledger_dir do
      statement('2609', [row('2026-09-10', -1000)], -1000)
      2.times { statement('2610', [row('2026-10-02', -349.86)], -1349.86) }

      text = File.read(path('2609'))
      assert_equal 1, text.scan(Frijolero::StatementBalance::MARK).size
      assert_equal ['2026-10-03 balance Liabilities:Amex  -1,000.00 - 349.86 MXN'], balances('2609')
    end
  end

  # The usual late charge, dated on the closing day, falls after the check: no rewrite.
  def test_rows_of_the_closing_day_in_the_next_statement_leave_that_line_alone
    with_ledger_dir do
      statement('2609', [row('2026-09-10', -1000)], -1000)
      before = File.read(path('2609'))

      statement('2610', [row('2026-10-03', -365.5)], -1365.5)

      assert_equal before, File.read(path('2609'))
    end
  end

  # The first statement of an account has no cutoff_day yet, and a PDF may print no balance.
  def test_no_line_without_a_cutoff_day_or_a_printed_balance
    with_ledger_dir do
      statement('2609', [row('2026-09-10', -1000)], -1000, config: AMEX.except('cutoff_day'))
      statement('2610', [row('2026-10-10', -1000)], nil)

      assert_empty balances('2609')
      assert_empty balances('2610')
    end
  end

  # One line per section. A move between them, dated after the close, leaves both balances.
  def test_multi_writes_one_line_per_section
    plata = { 'beancount_account' => 'Assets:Plata:Cuenta', 'cutoff_day' => 9,
              'accounts' => { 'Plata Cuenta' => 'Assets:Plata:Cuenta', 'Ahorro Flexible' => 'Assets:Plata:Ahorro' } }
    rows = [row('2026-10-20', 1000, 'account' => 'Plata Cuenta'),
            row('2026-11-10', -5.47, 'account' => 'Plata Cuenta', 'expense_account' => 'Assets:Plata:Ahorro'),
            row('2026-11-10', 8463.63, 'account' => 'Ahorro Flexible')]
    closings = [{ 'account' => 'Plata Cuenta', 'amount' => 994.53 },
                { 'account' => 'Ahorro Flexible', 'amount' => 8469.10 }]
    with_ledger_dir do
      statement('2610', rows, closings, key: 'Plata Banco', config: plata)

      assert_equal ['2026-11-09 balance Assets:Plata:Cuenta  994.53 + 5.47 MXN',
                    '2026-11-09 balance Assets:Plata:Ahorro  8,469.10 - 5.47 - 8,463.63 MXN'],
                   balances('2610', 'Plata Banco')
    end
  end

  # The consumer: rledger passes two months with both kinds of late charge, and a duplicate
  # fails the month that holds it by its amount.
  def test_rledger_passes_the_lines_and_fails_a_duplicate
    with_ledger_dir do |dir|
      statement('2608', [row('2026-08-10', -500), row('2026-09-03', -30)], -530)
      statement('2609', [row('2026-09-03', -20), row('2026-09-01', -40), row('2026-09-12', 530),
                         row('2026-10-01', -100)], -160)
      File.write(File.join(dir, 'main.beancount'), <<~BEANCOUNT)
        2026-01-01 open Liabilities:Amex
        2026-01-01 open Expenses:FIXME
        include "accounts/AMEX/AMEX 2608.beancount"
        include "accounts/AMEX/AMEX 2609.beancount"
      BEANCOUNT

      assert_empty Frijolero::Reports.check

      duplicate = "2026-09-15 * \"Duplicado\"\n  Liabilities:Amex  -377.00 MXN\n  Expenses:FIXME\n"
      File.write(path('2609'), duplicate, mode: 'a')
      errors = Frijolero::Reports.check

      assert_equal([['E2001', 'accounts/AMEX/AMEX 2609.beancount']], errors.map { |e| [e[:code], e[:file]] })
      m = Frijolero::App::BALANCE_FAILED.match(errors.first[:message])
      assert_equal BigDecimal('377'), (BigDecimal(m[:got]) - BigDecimal(m[:expected])).abs
    end
  end
end
