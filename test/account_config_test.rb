# frozen_string_literal: true

require 'test_helper'
require 'date'

class AccountConfigTest < Minitest::Test
  include TestHelpers

  def teardown; end

  def test_record_cutoff_writes_the_day_once_and_keeps_the_rest_of_the_file
    with_ledger_dir do |dir|
      path = File.join(dir, 'config', 'accounts.yaml')
      File.write(path, "# top\nAMEX:\n  beancount_account: \"Liabilities:Amex\"\n# tail\nBBVA:\n  cutoff_day: 22\n")

      Frijolero::AccountConfig.record_cutoff('AMEX', Date.new(2026, 9, 3))
      Frijolero::AccountConfig.record_cutoff('BBVA', Date.new(2026, 8, 23))

      expected = "# top\nAMEX:\n  beancount_account: \"Liabilities:Amex\"\n  cutoff_day: 3\n" \
                 "# tail\nBBVA:\n  cutoff_day: 22\n"
      assert_equal expected, File.read(path)
    end
  end

  def test_record_cutoff_stores_31_for_the_last_day_of_the_month
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), "CETES:\n  beancount_account: \"Assets:Cetes\"\n")

      Frijolero::AccountConfig.record_cutoff('CETES', Date.new(2026, 2, 28))

      assert_equal 31, Frijolero::Config.accounts['CETES']['cutoff_day']
    end
  end

  def test_parse_filename_with_space_separator
    result = Frijolero::AccountConfig.parse_filename('Amex 2501.pdf')
    assert_equal %w[Amex 2501], result
  end

  def test_parse_filename_with_multi_word_account
    result = Frijolero::AccountConfig.parse_filename('BBVA TDC 2501.pdf')
    assert_equal ['BBVA TDC', '2501'], result
  end

  def test_parse_filename_with_underscore_separator_is_unparseable
    result = Frijolero::AccountConfig.parse_filename('Amex_2501.json')
    assert_nil result
  end

  def test_parse_filename_with_invalid_format
    result = Frijolero::AccountConfig.parse_filename('invalid.pdf')
    assert_nil result
  end

  def test_parse_filename_strips_path
    result = Frijolero::AccountConfig.parse_filename('/path/to/Amex 2501.pdf')
    assert_equal %w[Amex 2501], result
  end

  def test_find_config_exact_match
    with_accounts_config do
      config = Frijolero::AccountConfig.find_config('Amex')
      assert_equal 'Liabilities:Amex', config['beancount_account']
    end
  end

  def test_find_config_not_found
    with_accounts_config do
      config = Frijolero::AccountConfig.find_config('Unknown')
      assert_nil config
    end
  end

  def test_find_config_is_case_sensitive
    with_accounts_config do
      config = Frijolero::AccountConfig.find_config('amex')
      assert_nil config
    end
  end

  def test_available_accounts
    with_accounts_config do
      accounts = Frijolero::AccountConfig.available_accounts
      assert_includes accounts, 'Amex'
      assert_includes accounts, 'BBVA'
    end
  end

  def test_closed_accounts_are_excluded_from_active_and_descriptions_but_still_found
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
        AMEX:
          beancount_account: "Liabilities:Amex"
        Old Card:
          beancount_account: "Liabilities:OldCard"
          closed: true
      YAML

      assert_equal ['AMEX'], Frijolero::AccountConfig.active.keys
      assert_equal ['AMEX'], Frijolero::AccountConfig.descriptions.keys
      assert_equal 'Liabilities:OldCard', Frijolero::AccountConfig.find_config('Old Card')['beancount_account']
    end
  end

  def test_descriptions_fall_back_to_key
    with_accounts_config do
      descriptions = Frijolero::AccountConfig.descriptions
      assert_equal 'Amex credit card, MXN', descriptions['Amex']
      assert_equal 'BBVA', descriptions['BBVA']
    end
  end

  private

  def with_accounts_config
    with_ledger_dir do |dir|
      FileUtils.cp(fixture_path('sample_accounts.yaml'), File.join(dir, 'config', 'accounts.yaml'))
      yield
    end
  end
end
