# frozen_string_literal: true

require "test_helper"

class AccountsTest < Minitest::Test
  include TestHelpers

  def test_extracts_accounts_from_file
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    assert_includes accounts.all, "Assets:Bank:BBVA"
    assert_includes accounts.all, "Assets:Bank:Banamex"
    assert_includes accounts.all, "Liabilities:Amex"
    assert_includes accounts.all, "Liabilities:BBVA:TDC"
    assert_includes accounts.all, "Expenses:Food"
    assert_includes accounts.all, "Expenses:Food:Coffee"
    assert_includes accounts.all, "Expenses:Transportation"
    assert_includes accounts.all, "Income:Salary"
    assert_includes accounts.all, "Equity:OpeningBalances"
  end

  def test_returns_sorted_accounts
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    assert_equal accounts.all, accounts.all.sort
  end

  def test_deduplicates_accounts
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    assert_equal 1, accounts.all.count { |a| a == "Expenses:Food" }
  end

  def test_returns_correct_count
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    assert_equal 9, accounts.all.size
  end

  def test_ignores_non_open_directives
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    refute accounts.all.any? { |a| a == "Expenses:FIXME" }
  end

  def test_search_returns_matching_accounts
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    results = accounts.search("Food")
    assert_equal ["Expenses:Food", "Expenses:Food:Coffee"], results
  end

  def test_search_is_case_insensitive
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    results = accounts.search("food")
    assert_equal ["Expenses:Food", "Expenses:Food:Coffee"], results
  end

  def test_search_matches_any_segment
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    results = accounts.search("bbva")
    assert_equal ["Assets:Bank:BBVA", "Liabilities:BBVA:TDC"], results
  end

  def test_search_with_nil_returns_all
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    assert_equal accounts.all, accounts.search(nil)
  end

  def test_search_with_empty_string_returns_all
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    assert_equal accounts.all, accounts.search("")
  end

  def test_search_with_no_matches_returns_empty
    accounts = Frijolero::Accounts.new(file: fixture_path("sample_accounts.beancount"))

    assert_equal [], accounts.search("nonexistent")
  end

  def test_raises_when_file_not_found
    assert_raises ArgumentError do
      Frijolero::Accounts.new(file: "/nonexistent/path.beancount")
    end
  end

  def test_raises_when_no_file_specified_and_no_config
    with_temp_config_dir do
      assert_raises ArgumentError do
        Frijolero::Accounts.new
      end
    end
  end

  def test_handles_empty_file
    with_temp_dir do |dir|
      empty_file = File.join(dir, "empty.beancount")
      File.write(empty_file, "")

      accounts = Frijolero::Accounts.new(file: empty_file)

      assert_equal [], accounts.all
    end
  end

  def test_handles_file_with_no_open_directives
    with_temp_dir do |dir|
      file = File.join(dir, "no_opens.beancount")
      File.write(file, <<~BEANCOUNT)
        ; Just comments
        2025-01-15 * "Transaction"
          Expenses:Food  50.00 MXN
          Assets:Bank
      BEANCOUNT

      accounts = Frijolero::Accounts.new(file: file)

      assert_equal [], accounts.all
    end
  end
end
