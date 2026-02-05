# frozen_string_literal: true

require "test_helper"

class AccountConfigTest < Minitest::Test
  include TestHelpers

  def setup
    @config_dir = Dir.mktmpdir
    setup_test_config(@config_dir)
  end

  def teardown
    FileUtils.rm_rf(@config_dir)
    Frijolero::Config.reload!
  end

  def test_parse_filename_with_space_separator
    result = Frijolero::AccountConfig.parse_filename("Amex 2501.pdf")
    assert_equal ["Amex", "2501"], result
  end

  def test_parse_filename_with_underscore_separator
    result = Frijolero::AccountConfig.parse_filename("Amex_2501.json")
    assert_equal ["Amex", "2501"], result
  end

  def test_parse_filename_with_multi_word_account
    result = Frijolero::AccountConfig.parse_filename("BBVA TDC 2501.pdf")
    assert_equal ["BBVA TDC", "2501"], result
  end

  def test_parse_filename_with_multi_word_underscore
    result = Frijolero::AccountConfig.parse_filename("BBVA_TDC_2501.json")
    assert_equal ["BBVA_TDC", "2501"], result
  end

  def test_parse_filename_with_invalid_format
    result = Frijolero::AccountConfig.parse_filename("invalid.pdf")
    assert_nil result
  end

  def test_parse_filename_strips_path
    result = Frijolero::AccountConfig.parse_filename("/path/to/Amex 2501.pdf")
    assert_equal ["Amex", "2501"], result
  end

  def test_find_config_exact_match
    with_accounts_config do
      config = Frijolero::AccountConfig.find_config("Amex")
      assert_equal "Liabilities:Amex", config["beancount_account"]
    end
  end

  def test_find_config_case_insensitive
    with_accounts_config do
      config = Frijolero::AccountConfig.find_config("amex")
      assert_equal "Liabilities:Amex", config["beancount_account"]
    end
  end

  def test_find_config_underscore_to_space
    with_accounts_config do
      config = Frijolero::AccountConfig.find_config("BBVA_TDC")
      assert_equal "Liabilities:BBVA", config["beancount_account"]
    end
  end

  def test_find_config_not_found
    with_accounts_config do
      config = Frijolero::AccountConfig.find_config("Unknown")
      assert_nil config
    end
  end

  def test_beancount_account_for_file
    with_accounts_config do
      account = Frijolero::AccountConfig.beancount_account_for_file("Amex_2501.json")
      assert_equal "Liabilities:Amex", account
    end
  end

  def test_available_accounts
    with_accounts_config do
      accounts = Frijolero::AccountConfig.available_accounts
      assert_includes accounts, "Amex"
      assert_includes accounts, "BBVA"
    end
  end

  private

  def setup_test_config(dir)
    Frijolero::Config.send(:remove_const, :CONFIG_DIR) if Frijolero::Config.const_defined?(:CONFIG_DIR, false)
    Frijolero::Config.const_set(:CONFIG_DIR, dir)
    Frijolero::Config.send(:remove_const, :CONFIG_FILE) if Frijolero::Config.const_defined?(:CONFIG_FILE, false)
    Frijolero::Config.const_set(:CONFIG_FILE, File.join(dir, "config.yaml"))
    Frijolero::Config.send(:remove_const, :ACCOUNTS_FILE) if Frijolero::Config.const_defined?(:ACCOUNTS_FILE, false)
    Frijolero::Config.const_set(:ACCOUNTS_FILE, File.join(dir, "accounts.yaml"))
    Frijolero::Config.send(:remove_const, :DETAILERS_DIR) if Frijolero::Config.const_defined?(:DETAILERS_DIR, false)
    Frijolero::Config.const_set(:DETAILERS_DIR, File.join(dir, "detailers"))
  end

  def with_accounts_config
    FileUtils.cp(fixture_path("sample_accounts.yaml"), Frijolero::Config.accounts_file)
    Frijolero::Config.reload!
    yield
  end
end
