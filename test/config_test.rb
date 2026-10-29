# frozen_string_literal: true

require 'test_helper'

class ConfigTest < Minitest::Test
  include TestHelpers

  def teardown; end

  def test_ledger_dir_raises_without_a_current_ledger
    assert_raises(Frijolero::NoLedger) { Frijolero::Config.ledger_dir }
  end

  def test_ledger_dir_is_the_repo_of_the_current_ledger
    with_ledger_dir do |dir|
      assert_equal Frijolero::Ledger.current.repo_dir, Frijolero::Config.ledger_dir
      assert_equal dir, Frijolero::Config.ledger_dir
    end
  end

  def test_main_file_defaults_to_main_beancount
    with_ledger_dir do |dir|
      assert_equal File.join(dir, 'main.beancount'), Frijolero::Config.main_file
    end
  end

  def test_main_file_is_the_one_of_the_ledger
    with_ledger_dir(main_file: 'moneys.beancount') do |dir|
      assert_equal File.join(dir, 'moneys.beancount'), Frijolero::Config.main_file
    end
  end

  def test_account_opens_file_is_the_main_file_by_default
    with_ledger_dir do |dir|
      assert_equal File.join(dir, 'main.beancount'), Frijolero::Config.account_opens_file
    end
  end

  def test_account_opens_file_is_the_separate_file_when_it_exists
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'account_opens.beancount'), '')
      assert_equal File.join(dir, 'account_opens.beancount'), Frijolero::Config.account_opens_file
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
  def test_pdf_key_mirrors_the_accounts_subtree_under_the_ledger_prefix
    with_ledger_dir do
      assert_equal 'frijolero/accounts/AMEX Aeromexico/AMEX Aeromexico 2508.pdf',
                   Frijolero::Config.pdf_key('AMEX Aeromexico', '2508')
    end
  end

  def test_pdf_key_of_another_ledger_uses_its_own_prefix
    ledger = Frijolero::Ledger.new(id: 'abc', owner_id: 2, name: 'Otro', main_file: 'main.beancount',
                                   pdf_prefix: 'frijolero/ledgers/abc', dir: '/x', repo_dir: '/x/repo')
    Frijolero::Ledger.with(ledger) do
      assert_equal 'frijolero/ledgers/abc/accounts/AMEX/AMEX 2508.pdf', Frijolero::Config.pdf_key('AMEX', '2508')
    end
  end

  def test_accounts_returns_empty_hash_when_file_absent
    with_ledger_dir do
      assert_equal({}, Frijolero::Config.accounts)
    end
  end

  def test_accounts_loads_from_config_accounts_yaml
    with_ledger_dir do |dir|
      FileUtils.cp(fixture_path('sample_accounts.yaml'), File.join(dir, 'config', 'accounts.yaml'))

      assert_equal 'Liabilities:Amex', Frijolero::Config.accounts['Amex']['beancount_account']
    end
  end

  # A key is a directory of the ledger and part of its file names: `../` would leave the ledger.
  def test_accounts_skip_a_key_that_could_leave_the_ledger
    with_ledger_dir do |dir|
      keys = ['AMEX Aeromexico', 'Nómina_2-b.c', '../other', 'a/b', '.', '..', 1234, '...']
      File.write(File.join(dir, 'config', 'accounts.yaml'),
                 YAML.dump(keys.to_h { |key| [key, { 'beancount_account' => 'Assets:X' }] }))

      assert_equal ['AMEX Aeromexico', 'Nómina_2-b.c', '...'], Frijolero::Config.accounts.keys
    end
  end

  def test_data_dir_raises_without_env
    without_env('DATA_DIR') do
      error = assert_raises(RuntimeError) { Frijolero::Config.data_dir }
      assert_match(/DATA_DIR is not set/, error.message)
    end
  end

  def test_the_job_log_the_uploads_and_the_pdfs_live_next_to_the_repo
    with_ledger_dir do |dir|
      ledger = File.dirname(dir)
      assert_equal File.join(ledger, 'jobs.jsonl'), Frijolero::Config.jobs_file
      assert_equal File.join(ledger, 'incoming'), Frijolero::Config.incoming_dir
      assert_equal File.join(ledger, 'pdfs'), Frijolero::Config.pdfs_dir
    end
  end

  def test_llm_timeout_defaults_to_the_constant_and_reads_the_env
    assert_equal 900, with_env('LLM_TIMEOUT' => nil) { Frijolero::Config.llm_timeout }
    assert_equal 1500, with_env('LLM_TIMEOUT' => '1500') { Frijolero::Config.llm_timeout }
  end

  # The prompts are the app's, the same for every ledger, and no ledger is needed to read them.
  def test_prompt_spec_reads_the_prompts_of_the_app
    spec = Frijolero::Config.prompt_spec('default')

    assert_equal File.expand_path('../prompts', __dir__), Frijolero::Config.prompts_dir
    assert_equal 'default', spec['_prompt']
    assert_equal 'json_schema', spec['format']['type']
  end

  def test_prompt_spec_assembles_folder_with_wrapped_schema
    spec = Frijolero::PromptSpec.load('bbva', fixture_path('prompts'))

    assert_equal 'gpt-test-bbva', spec['model']
    assert_includes spec['instructions'], 'BBVA test instructions'
    assert_equal 'json_schema', spec['format']['type']
    # wrapped schema.json keys (name/strict/schema) merge into format
    assert_equal 'transactions_bbva', spec['format']['name']
    assert_equal({ 'type' => 'array' }, spec['format']['schema']['properties']['transactions'])
  end

  def test_prompt_spec_accepts_bare_schema
    spec = Frijolero::PromptSpec.load('default', fixture_path('prompts'))

    # default fixture's schema.json is a bare JSON schema, inlined as format.schema
    assert_equal 'json_schema', spec['format']['type']
    assert_equal({ 'type' => 'array' }, spec['format']['schema']['properties']['transactions'])
  end

  # The usage record names the folder that answered, so a fallback counts as default.
  def test_prompt_spec_falls_back_to_default
    spec = Frijolero::PromptSpec.load('unknown', fixture_path('prompts'))

    assert_equal 'gpt-test-default', spec['model']
    assert_equal 'default', spec['_prompt']
  end

  def test_prompt_spec_raises_without_default_fallback
    with_temp_dir do |dir|
      error = assert_raises(RuntimeError) { Frijolero::PromptSpec.load('unknown', dir) }
      assert_match(/no 'default' fallback/, error.message)
    end
  end

  def test_prompt_spec_raises_when_schema_missing
    with_default_prompt_copy do |dir|
      FileUtils.rm(File.join(dir, 'default', 'schema.json'))

      error = assert_raises(RuntimeError) { Frijolero::PromptSpec.load('default', dir) }
      assert_match(/Missing prompt file/, error.message)
    end
  end

  def test_prompt_spec_raises_when_spec_keys_missing
    with_default_prompt_copy do |dir|
      File.write(File.join(dir, 'default', 'spec.json'), '{"model":"x"}')

      error = assert_raises(RuntimeError) { Frijolero::PromptSpec.load('default', dir) }
      assert_match(/missing keys: format/, error.message)
    end
  end

  def test_classify_prompt_is_valid_and_consistent
    spec = Frijolero::Config.prompt_spec('classify')

    assert_equal ['unknown'], spec['format']['schema']['properties']['account']['enum']
    assert_equal 'statement_classification', spec['format']['name']
    assert_includes spec['format']['schema']['required'], 'period_end'
  end

  private

  # A copy of the default fixture to break, so no test writes into a real prompts folder.
  def with_default_prompt_copy
    with_temp_dir do |dir|
      FileUtils.cp_r(fixture_path('prompts/default'), dir)
      yield dir
    end
  end
end
