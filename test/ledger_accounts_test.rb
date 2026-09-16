# frozen_string_literal: true

require 'test_helper'

class LedgerAccountsTest < Minitest::Test
  include TestHelpers

  # An adopted ledger keeps its opens wherever it likes; the main file's includes reach them.
  def test_follows_the_includes_of_the_main_file_one_level_down
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'main.beancount'), <<~BEAN)
        include "opens.beancount"
        include "accounts/*.beancount"
        2020-01-01 open Assets:Main
      BEAN
      File.write(File.join(dir, 'opens.beancount'), "2020-01-01 open Liabilities:TDC\ninclude \"deeper.beancount\"\n")
      File.write(File.join(dir, 'deeper.beancount'), "2020-01-01 open Assets:Deeper\n")
      FileUtils.mkdir_p(File.join(dir, 'accounts'))
      File.write(File.join(dir, 'accounts', 'x.beancount'), "2020-01-01 open Assets:Glob\n")

      assert_equal %w[Assets:Glob Assets:Main Liabilities:TDC], Frijolero::LedgerAccounts.all
    end
  end
end
