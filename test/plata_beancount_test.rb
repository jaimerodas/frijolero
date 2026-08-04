# frozen_string_literal: true

require 'test_helper'
require 'English'

# The unit tests assert on strings. This one hands the generated ledger to a real
# Beancount parser, which is the only thing that can tell us the output is valid --
# several past defects (a reduction against a nonexistent 0.00 lot, share counts
# rendered in scientific notation) produced text that looked plausible and failed
# to load.
#
# Skips when no checker is installed, so the suite stays runnable without one.
class PlataBeancountTest < Minitest::Test
  include TestHelpers

  CHECKER = 'bean-check'

  def test_generated_ledger_loads_without_errors
    skip "#{CHECKER} not installed" unless checker_available?

    with_temp_dir do |dir|
      path = File.join(dir, 'ledger.beancount')
      File.write(path, preamble + generated)

      output = `#{CHECKER} #{path} 2>&1`

      assert_predicate $CHILD_STATUS, :success?, "#{CHECKER} rejected the ledger:\n#{output}"
    end
  end

  private

  def checker_available?
    system("command -v #{CHECKER} > /dev/null 2>&1")
  end

  def preamble
    File.read(fixture_path('sample_plata_preamble.beancount'), encoding: 'UTF-8')
  end

  def generated
    io = StringIO.new
    Frijolero::Converters::Plata.new(
      input: fixture_path('sample_plata.json'),
      account: 'Assets:Investments:Plata',
      targets: Frijolero::Converters::AccountTargets.new(
        counterpart: 'Assets:BBVA',
        dividend: 'Income:Dividends:Plata',
        interest: 'Income:Interest',
        tax: 'Expenses:Taxes:ISR',
        gains: 'Income:Gains:Plata',
        fees: 'Expenses:Fees:Plata',
        withholding: 'Expenses:Taxes:Withholding:USA'
      )
    ).run_to(io)
    io.string
  end
end
