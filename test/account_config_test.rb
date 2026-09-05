# frozen_string_literal: true

require 'test_helper'

class AccountConfigTest < Minitest::Test
  include TestHelpers

  def teardown
    Frijolero::Config.reload!
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

  private

  def with_accounts_config
    with_ledger_dir do |dir|
      FileUtils.cp(fixture_path('sample_accounts.yaml'), File.join(dir, 'config', 'accounts.yaml'))
      Frijolero::Config.reload!
      yield
    end
  end
end
