# frozen_string_literal: true

require 'test_helper'

# The unit tests assert on strings. This one hands the generated ledger to
# rustledger, the checker the app runs, which is the only thing that can tell us
# the output is valid -- several past defects (a reduction against a nonexistent
# 0.00 lot, share counts rendered in scientific notation) produced text that looked
# plausible and failed to load.
#
# It also proves more than parseability: the converter's own closing `balance`
# directives are checked against the postings it emitted, so a split that loses
# basis or a dropped movement fails here rather than in the reports months later.
#
# Skips when rustledger is not installed.
class AlpacaBeancountTest < Minitest::Test
  include TestHelpers

  def test_generated_ledger_loads_without_errors
    with_temp_dir do |dir|
      path = File.join(dir, 'ledger.beancount')
      File.write(path, preamble + generated)

      output, status = rledger('check', '--no-cache', path)

      assert_predicate status, :success?, "rledger rejected the ledger:\n#{output}"
    end
  end

  private

  def preamble
    File.read(fixture_path('sample_plata_preamble.beancount'), encoding: 'UTF-8')
  end

  def generated
    io = StringIO.new
    Frijolero::Converters::Alpaca.new(
      input: fixture_path('sample_plata.json'),
      account: 'Assets:Investments:Plata',
      targets: Frijolero::Converters::AccountTargets.new(
        dividend: 'Income:Dividends:Plata',
        interest: 'Income:Interest',
        gains: 'Income:Gains:Plata',
        fees: 'Expenses:Fees:Plata',
        withholding: 'Expenses:Taxes:Withholding:USA'
      )
    ).run_to(io)
    io.string
  end
end
