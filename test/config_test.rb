# frozen_string_literal: true

require 'test_helper'

class ConfigTest < Minitest::Test
  include TestHelpers

  def teardown
    Frijolero::Config.reload!
  end

  def test_ledger_dir_raises_without_env
    ENV.delete('LEDGER_DIR')
    error = assert_raises(RuntimeError) { Frijolero::Config.ledger_dir }
    assert_match(/LEDGER_DIR is not set/, error.message)
  end

  def test_main_file_defaults_to_transactions_beancount
    with_ledger_dir do |dir|
      assert_equal File.join(dir, 'transactions.beancount'), Frijolero::Config.main_file
    end
  end

  def test_main_file_honors_override
    with_ledger_dir do |dir|
      ENV['LEDGER_MAIN_FILE'] = 'main.beancount'
      assert_equal File.join(dir, 'main.beancount'), Frijolero::Config.main_file
    end
  end

  def test_rules_path_with_two_word_key
    with_ledger_dir do |dir|
      expected = File.join(dir, 'config', 'rules', 'BBVA TDC.yaml')
      assert_equal expected, Frijolero::Config.rules_path('BBVA TDC')
    end
  end

  def test_rules_path_nil_when_account_key_nil
    with_ledger_dir do
      assert_nil Frijolero::Config.rules_path(nil)
    end
  end

  def test_statement_path_builds_accounts_subtree
    with_ledger_dir do |dir|
      expected = File.join(dir, 'accounts', 'AMEX Aeromexico', 'AMEX Aeromexico 2508.beancount')
      assert_equal expected, Frijolero::Config.statement_path('AMEX Aeromexico', '2508', 'beancount')
    end
  end

  # The bucket mirrors the ledger layout, spaces and all: percent-encoding the space
  # is the signer's job, and doing it here would sign a key nobody stored.
  def test_pdf_key_mirrors_the_accounts_subtree
    assert_equal 'accounts/AMEX Aeromexico/AMEX Aeromexico 2508.pdf',
                 Frijolero::Config.pdf_key('AMEX Aeromexico', '2508')
  end

  def test_accounts_returns_empty_hash_when_file_absent
    with_ledger_dir do
      assert_equal({}, Frijolero::Config.accounts)
    end
  end

  def test_accounts_loads_from_config_accounts_yaml
    with_ledger_dir do |dir|
      FileUtils.cp(fixture_path('sample_accounts.yaml'), File.join(dir, 'config', 'accounts.yaml'))
      Frijolero::Config.reload!

      assert_equal 'Liabilities:Amex', Frijolero::Config.accounts['Amex']['beancount_account']
    end
  end

  def test_data_dir_is_parent_of_ledger_dir
    with_ledger_dir do |dir|
      assert_equal File.dirname(dir), Frijolero::Config.data_dir
    end
  end

  def test_jobs_file_lives_under_data_dir
    with_ledger_dir do |dir|
      assert_equal File.join(File.dirname(dir), 'jobs.jsonl'), Frijolero::Config.jobs_file
    end
  end

  def test_incoming_dir_lives_under_data_dir
    with_ledger_dir do |dir|
      assert_equal File.join(File.dirname(dir), 'incoming'), Frijolero::Config.incoming_dir
    end
  end

  def test_openai_api_key_reads_env
    with_ledger_dir do
      old = ENV.fetch('OPENAI_API_KEY', nil)
      ENV['OPENAI_API_KEY'] = 'test_key_123'
      assert_equal 'test_key_123', Frijolero::Config.openai_api_key
    ensure
      ENV['OPENAI_API_KEY'] = old
    end
  end

  def test_openai_poll_timeout_defaults_to_constant
    with_ledger_dir do
      old = ENV.delete('OPENAI_POLL_TIMEOUT')
      assert_equal Frijolero::OpenAIClient::POLL_TIMEOUT_SECONDS, Frijolero::Config.openai_poll_timeout
    ensure
      ENV['OPENAI_POLL_TIMEOUT'] = old
    end
  end

  def test_openai_poll_timeout_reads_env_override
    with_ledger_dir do
      old = ENV.fetch('OPENAI_POLL_TIMEOUT', nil)
      ENV['OPENAI_POLL_TIMEOUT'] = '1500'
      assert_equal 1500, Frijolero::Config.openai_poll_timeout
    ensure
      ENV['OPENAI_POLL_TIMEOUT'] = old
    end
  end

  def test_openai_prompt_spec_assembles_folder_with_wrapped_schema
    with_ledger_dir do
      copy_prompt_fixtures

      spec = Frijolero::Config.openai_prompt_spec('bbva')

      assert_equal 'gpt-test-bbva', spec['model']
      assert_includes spec['instructions'], 'BBVA test instructions'
      assert_equal 'json_schema', spec['format']['type']
      # wrapped schema.json keys (name/strict/schema) merge into format
      assert_equal 'transactions_bbva', spec['format']['name']
      assert_equal({ 'type' => 'array' }, spec['format']['schema']['properties']['transactions'])
    end
  end

  def test_openai_prompt_spec_accepts_bare_schema
    with_ledger_dir do
      copy_prompt_fixtures

      spec = Frijolero::Config.openai_prompt_spec('default')

      # default fixture's schema.json is a bare JSON schema, inlined as format.schema
      assert_equal 'json_schema', spec['format']['type']
      assert_equal({ 'type' => 'array' }, spec['format']['schema']['properties']['transactions'])
    end
  end

  def test_openai_prompt_spec_falls_back_to_default
    with_ledger_dir do
      copy_prompt_fixtures

      spec = Frijolero::Config.openai_prompt_spec('unknown')

      assert_equal 'gpt-test-default', spec['model']
    end
  end

  def test_openai_prompt_spec_raises_without_default_fallback
    with_ledger_dir do
      error = assert_raises(RuntimeError) { Frijolero::Config.openai_prompt_spec('unknown') }
      assert_match(/no 'default' fallback/, error.message)
    end
  end

  def test_openai_prompt_spec_raises_when_schema_missing
    with_ledger_dir do
      copy_prompt_fixtures
      FileUtils.rm(File.join(Frijolero::Config.prompts_dir, 'default', 'schema.json'))

      error = assert_raises(RuntimeError) { Frijolero::Config.openai_prompt_spec('default') }
      assert_match(/Missing prompt file/, error.message)
    end
  end

  def test_openai_prompt_spec_raises_when_spec_keys_missing
    with_ledger_dir do
      copy_prompt_fixtures
      File.write(File.join(Frijolero::Config.prompts_dir, 'default', 'spec.json'), '{"model":"x"}')

      error = assert_raises(RuntimeError) { Frijolero::Config.openai_prompt_spec('default') }
      assert_match(/missing keys: format/, error.message)
    end
  end

  def test_classify_template_is_valid_and_consistent
    templates_dir = File.expand_path('../lib/frijolero/templates/prompts', __dir__)
    spec = Frijolero::PromptSpec.load('classify', templates_dir)

    assert_equal ['unknown'], spec['format']['schema']['properties']['account']['enum']
    assert_equal 'statement_classification', spec['format']['name']
    assert_includes spec['format']['schema']['required'], 'period_end'
  end

  private

  def copy_prompt_fixtures
    FileUtils.mkdir_p(Frijolero::Config.prompts_dir)
    %w[default bbva].each do |type|
      FileUtils.cp_r(fixture_path("prompts/#{type}"), File.join(Frijolero::Config.prompts_dir, type))
    end
  end
end
