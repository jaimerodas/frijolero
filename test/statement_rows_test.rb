# frozen_string_literal: true

require 'test_helper'

class StatementRowsTest < Minitest::Test
  include TestHelpers

  CONFIG = { 'beancount_account' => 'Liabilities:Amex' }.freeze

  def test_a_row_carries_its_transactions_header_line
    with_temp_dir do |dir|
      path = File.join(dir, 'sample.beancount')
      File.write(path, <<~BEANCOUNT)
        2025-08-01 * "OXXO"
          Liabilities:Amex  -100.00 MXN
          Expenses:Food

        2025-08-02 * "UBER"
          Liabilities:Amex  -50.00 MXN
          Expenses:FIXME
      BEANCOUNT

      rows = Frijolero::StatementRows.read(path, CONFIG)

      assert_equal([1, 5], rows.map { |row| row[:line] })
    end
  end
end
