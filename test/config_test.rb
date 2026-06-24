# frozen_string_literal: true

require 'test_helper'

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
    FileUtils.cp(fixture_path('sample_config.yaml'), Frijolero::Config.config_file)
    Frijolero::Config.reload!
    assert_equal true, Frijolero::Config.initialized?
  end

  def test_loads_config_values
    FileUtils.cp(fixture_path('sample_config.yaml'), Frijolero::Config.config_file)
    Frijolero::Config.reload!

    assert_equal 'test_key_123', Frijolero::Config.openai_api_key
  end

  def test_openai_prompt_spec_assembles_folder_with_wrapped_schema
    copy_prompt_fixtures

    spec = Frijolero::Config.openai_prompt_spec('bbva')

    assert_equal 'gpt-test-bbva', spec['model']
    assert_includes spec['instructions'], 'BBVA test instructions'
    assert_equal 'json_schema', spec['format']['type']
    # wrapped schema.json keys (name/strict/schema) merge into format
    assert_equal 'transactions_bbva', spec['format']['name']
    assert_equal({ 'type' => 'array' }, spec['format']['schema']['properties']['transactions'])
  end

  def test_openai_prompt_spec_accepts_bare_schema
    copy_prompt_fixtures

    spec = Frijolero::Config.openai_prompt_spec('default')

    # default fixture's schema.json is a bare JSON schema, inlined as format.schema
    assert_equal 'json_schema', spec['format']['type']
    assert_equal({ 'type' => 'array' }, spec['format']['schema']['properties']['transactions'])
  end

  def test_openai_prompt_spec_falls_back_to_default
    copy_prompt_fixtures

    spec = Frijolero::Config.openai_prompt_spec('unknown')

    assert_equal 'gpt-test-default', spec['model']
  end

  def test_openai_prompt_spec_raises_without_default_fallback
    error = assert_raises(RuntimeError) { Frijolero::Config.openai_prompt_spec('unknown') }
    assert_match(/no 'default' fallback/, error.message)
  end

  def test_openai_prompt_spec_raises_when_schema_missing
    copy_prompt_fixtures
    FileUtils.rm(File.join(Frijolero::Config.prompts_dir, 'default', 'schema.json'))

    error = assert_raises(RuntimeError) { Frijolero::Config.openai_prompt_spec('default') }
    assert_match(/Missing prompt file/, error.message)
  end

  def test_openai_prompt_spec_raises_when_spec_keys_missing
    copy_prompt_fixtures
    File.write(File.join(Frijolero::Config.prompts_dir, 'default', 'spec.json'), '{"model":"x"}')

    error = assert_raises(RuntimeError) { Frijolero::Config.openai_prompt_spec('default') }
    assert_match(/missing keys: format/, error.message)
  end

  def test_openai_poll_timeout_defaults_to_constant
    Frijolero::Config.reload!

    assert_equal Frijolero::OpenAIClient::POLL_TIMEOUT_SECONDS, Frijolero::Config.openai_poll_timeout
  end

  def test_openai_poll_timeout_reads_override
    File.write(Frijolero::Config.config_file, "openai_poll_timeout: 1500\n")
    Frijolero::Config.reload!

    assert_equal 1500, Frijolero::Config.openai_poll_timeout
  end

  def test_loads_accounts
    FileUtils.cp(fixture_path('sample_config.yaml'), Frijolero::Config.config_file)
    FileUtils.cp(fixture_path('sample_accounts.yaml'), Frijolero::Config.accounts_file)
    Frijolero::Config.reload!

    accounts = Frijolero::Config.accounts
    assert_equal 'Liabilities:Amex', accounts['Amex']['beancount_account']
  end

  def test_detailer_config_path
    path = Frijolero::Config.detailer_config_path('Amex')
    assert_equal File.join(@temp_dir, 'detailers', 'amex.yaml'), path
  end

  def test_detailer_config_path_with_spaces
    path = Frijolero::Config.detailer_config_path('BBVA TDC')
    assert_equal File.join(@temp_dir, 'detailers', 'bbva_tdc.yaml'), path
  end

  def test_paths_expansion
    FileUtils.cp(fixture_path('sample_config.yaml'), Frijolero::Config.config_file)
    Frijolero::Config.reload!

    assert_equal '/tmp/statements', Frijolero::Config.statements_input_dir
    assert_equal '/tmp/main.beancount', Frijolero::Config.beancount_main_file
    assert_equal '/tmp/accounts.beancount', Frijolero::Config.beancount_accounts_file
  end

  def test_statements_output_dir_derives_from_main_file
    FileUtils.cp(fixture_path('sample_config.yaml'), Frijolero::Config.config_file)
    Frijolero::Config.reload!

    assert_equal '/tmp', Frijolero::Config.statements_output_dir
  end

  def test_statements_output_dir_raises_without_main_file
    Frijolero::Config.reload!

    assert_raises(RuntimeError) { Frijolero::Config.statements_output_dir }
  end

  private

  def copy_prompt_fixtures
    FileUtils.mkdir_p(Frijolero::Config.prompts_dir)
    %w[default bbva].each do |type|
      FileUtils.cp_r(fixture_path("prompts/#{type}"), File.join(Frijolero::Config.prompts_dir, type))
    end
  end

  def setup_test_config(dir)
    Frijolero::Config.send(:remove_const, :CONFIG_DIR) if Frijolero::Config.const_defined?(:CONFIG_DIR, false)
    Frijolero::Config.const_set(:CONFIG_DIR, dir)
    Frijolero::Config.send(:remove_const, :CONFIG_FILE) if Frijolero::Config.const_defined?(:CONFIG_FILE, false)
    Frijolero::Config.const_set(:CONFIG_FILE, File.join(dir, 'config.yaml'))
    Frijolero::Config.send(:remove_const, :ACCOUNTS_FILE) if Frijolero::Config.const_defined?(:ACCOUNTS_FILE, false)
    Frijolero::Config.const_set(:ACCOUNTS_FILE, File.join(dir, 'accounts.yaml'))
    Frijolero::Config.send(:remove_const, :DETAILERS_DIR) if Frijolero::Config.const_defined?(:DETAILERS_DIR, false)
    Frijolero::Config.const_set(:DETAILERS_DIR, File.join(dir, 'detailers'))
    Frijolero::Config.send(:remove_const, :PROMPTS_DIR) if Frijolero::Config.const_defined?(:PROMPTS_DIR, false)
    Frijolero::Config.const_set(:PROMPTS_DIR, File.join(dir, 'prompts'))
  end

  def restore_config(original_dir)
    Frijolero::Config.send(:remove_const, :CONFIG_DIR) if Frijolero::Config.const_defined?(:CONFIG_DIR, false)
    Frijolero::Config.const_set(:CONFIG_DIR, original_dir)
    Frijolero::Config.send(:remove_const, :CONFIG_FILE) if Frijolero::Config.const_defined?(:CONFIG_FILE, false)
    Frijolero::Config.const_set(:CONFIG_FILE, File.join(original_dir, 'config.yaml'))
    Frijolero::Config.send(:remove_const, :ACCOUNTS_FILE) if Frijolero::Config.const_defined?(:ACCOUNTS_FILE, false)
    Frijolero::Config.const_set(:ACCOUNTS_FILE, File.join(original_dir, 'accounts.yaml'))
    Frijolero::Config.send(:remove_const, :DETAILERS_DIR) if Frijolero::Config.const_defined?(:DETAILERS_DIR, false)
    Frijolero::Config.const_set(:DETAILERS_DIR, File.join(original_dir, 'detailers'))
    Frijolero::Config.send(:remove_const, :PROMPTS_DIR) if Frijolero::Config.const_defined?(:PROMPTS_DIR, false)
    Frijolero::Config.const_set(:PROMPTS_DIR, File.join(original_dir, 'prompts'))
  end
end
