# frozen_string_literal: true

require 'test_helper'

class LedgerAccountsTest < Minitest::Test
  include TestHelpers

  # An adopted ledger keeps its opens wherever it likes; the includes reach them, at any depth.
  def test_follows_every_include_of_the_ledger
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

      assert_equal %w[Assets:Deeper Assets:Glob Assets:Main Liabilities:TDC], Frijolero::LedgerAccounts.active
    end
  end

  # The editors still open on a ledger that LedgerFiles refuses, so the badge can say why.
  def test_an_unsafe_ledger_has_no_accounts
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'main.beancount'), %(2020-01-01 open Assets:Main\ninclude "/etc/hosts"\n))

      assert_empty Frijolero::LedgerAccounts.active
    end
  end

  # What the autocomplete offers: an account a rule names but no `open` line opens, or one
  # that is closed, would fail the ledger check the moment a posting used it.
  def test_active_leaves_out_accounts_only_a_rule_names_and_closed_ones
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'main.beancount'), <<~BEAN)
        2020-01-01 open Assets:Bank
        2020-01-01 open Liabilities:OldCard
        2024-06-30 close Liabilities:OldCard
      BEAN
      FileUtils.mkdir_p(File.join(dir, 'config', 'rules'))
      File.write(File.join(dir, 'config', 'rules', 'Bank.yaml'), "include:\n  BOOK: { account: Expenses:Books }\n")

      assert_equal %w[Assets:Bank], Frijolero::LedgerAccounts.active
    end
  end
end
