# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  include TestHelpers

  def setup
    @original_config_dir = Frijolero::Config::CONFIG_DIR
    @temp_dir = Dir.mktmpdir
    setup_test_config(@temp_dir)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
    restore_config(@original_config_dir)
    Frijolero::Config.reload!
  end

  def test_initialized_returns_false_when_no_config
    assert_equal false, Frijolero::Config.initialized?
  end

  def test_initialized_returns_true_when_config_exists
    FileUtils.cp(fixture_path("sample_config.yaml"), Frijolero::Config.config_file)
    Frijolero::Config.reload!
    assert_equal true, Frijolero::Config.initialized?
  end

  def test_loads_config_values
    FileUtils.cp(fixture_path("sample_config.yaml"), Frijolero::Config.config_file)
    Frijolero::Config.reload!

    assert_equal "test_key_123", Frijolero::Config.openai_api_key
    assert_equal "pmpt_default", Frijolero::Config.openai_prompt("default")
    assert_equal "pmpt_bbva", Frijolero::Config.openai_prompt("bbva")
  end

  def test_openai_prompt_falls_back_to_default
    FileUtils.cp(fixture_path("sample_config.yaml"), Frijolero::Config.config_file)
    Frijolero::Config.reload!

    assert_equal "pmpt_default", Frijolero::Config.openai_prompt("unknown")
  end

  def test_loads_accounts
    FileUtils.cp(fixture_path("sample_config.yaml"), Frijolero::Config.config_file)
    FileUtils.cp(fixture_path("sample_accounts.yaml"), Frijolero::Config.accounts_file)
    Frijolero::Config.reload!

    accounts = Frijolero::Config.accounts
    assert_equal "Liabilities:Amex", accounts["Amex"]["beancount_account"]
  end

  def test_detailer_config_path
    path = Frijolero::Config.detailer_config_path("Amex")
    assert_equal File.join(@temp_dir, "detailers", "amex.yaml"), path
  end

  def test_detailer_config_path_with_spaces
    path = Frijolero::Config.detailer_config_path("BBVA TDC")
    assert_equal File.join(@temp_dir, "detailers", "bbva_tdc.yaml"), path
  end

  def test_paths_expansion
    FileUtils.cp(fixture_path("sample_config.yaml"), Frijolero::Config.config_file)
    Frijolero::Config.reload!

    assert_equal "/tmp/statements", Frijolero::Config.statements_input_dir
    assert_equal "/tmp/output", Frijolero::Config.statements_output_dir
    assert_equal "/tmp/main.beancount", Frijolero::Config.beancount_main_file
    assert_equal "/tmp/accounts.beancount", Frijolero::Config.beancount_accounts_file
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

  def restore_config(original_dir)
    Frijolero::Config.send(:remove_const, :CONFIG_DIR) if Frijolero::Config.const_defined?(:CONFIG_DIR, false)
    Frijolero::Config.const_set(:CONFIG_DIR, original_dir)
    Frijolero::Config.send(:remove_const, :CONFIG_FILE) if Frijolero::Config.const_defined?(:CONFIG_FILE, false)
    Frijolero::Config.const_set(:CONFIG_FILE, File.join(original_dir, "config.yaml"))
    Frijolero::Config.send(:remove_const, :ACCOUNTS_FILE) if Frijolero::Config.const_defined?(:ACCOUNTS_FILE, false)
    Frijolero::Config.const_set(:ACCOUNTS_FILE, File.join(original_dir, "accounts.yaml"))
    Frijolero::Config.send(:remove_const, :DETAILERS_DIR) if Frijolero::Config.const_defined?(:DETAILERS_DIR, false)
    Frijolero::Config.const_set(:DETAILERS_DIR, File.join(original_dir, "detailers"))
  end
end
