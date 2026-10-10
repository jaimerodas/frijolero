# frozen_string_literal: true

require 'test_helper'

# The unit tests assert on strings. This one hands a converted month to rustledger,
# the checker the app runs. rustledger checks the converter's own balance
# assertions (the cash and every holding) against the postings it wrote, and the
# interest that the lots produce must equal the statement's "Intereses del
# período": the coupon plus the discount of the CETES that matured.
#
# Skips when rustledger is not installed.
class CetesDirectoBeancountTest < Minitest::Test
  include TestHelpers

  def test_generated_month_passes_the_check
    with_ledger do |path|
      output, status = rledger('check', '--no-cache', path)

      assert_predicate status, :success?, "rledger rejected the month:\n#{output}"
    end
  end

  def test_interest_equals_the_period_interest_of_the_statement
    with_ledger do |path|
      output, = rledger('query', '--no-cache', '-q', '-f', 'csv', path,
                        "SELECT SUM(number) WHERE account = 'Income:Interest'")

      assert_equal(-765, BigDecimal(output.lines.last))
    end
  end

  private

  def with_ledger
    with_temp_dir do |dir|
      path = File.join(dir, 'ledger.beancount')
      File.write(path, File.read(fixture_path('sample_cetes_directo_preamble.beancount')) + generated)
      yield path
    end
  end

  def generated
    io = StringIO.new
    Frijolero::Converters::CetesDirecto.new(
      input: fixture_path('sample_cetes_directo.json'),
      account: 'Assets:Investments:CETESDirecto',
      targets: Frijolero::Converters::AccountTargets.new(
        counterpart: 'Assets:BBVA', interest: 'Income:Interest',
        tax: 'Expenses:Taxes:ISR', gains: 'Income:Gains:CetesDirecto'
      )
    ).run_to(io)
    io.string
  end
end
