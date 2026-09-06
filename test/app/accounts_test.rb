# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'fileutils'

class AccountsTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  class FakeRepo
    attr_reader :messages

    def initialize
      @messages = []
    end

    def commit_and_push(message)
      @messages << message
    end
  end

  class FakeB2
    attr_reader :prefixes
    attr_accessor :entries, :error

    def initialize
      @prefixes = []
      @entries = []
    end

    def list(prefix)
      @prefixes << prefix
      raise Frijolero::B2::Error.new(@error, status: 403) if @error

      @entries
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = @dir
    FileUtils.mkdir_p(File.join(@dir, 'config'))
    File.write(File.join(@dir, 'config', 'accounts.yaml'), <<~YAML)
      # Account Configuration
      # maps keys to accounts

      AMEX:
        beancount_account: "Liabilities:Amex"
        openai_prompt_type: default
      # Alpaca statements, not the advisor PDF
      BBVA TDC:
        beancount_account: "Assets:BBVA"
        # kept for the classifier
        description: "Tarjeta BBVA"
      Openbank:
        closed: true
        beancount_account: "Assets:Openbank"
      CETES:
        beancount_account: "Assets:CETES"
        converter_type: cetes_directo
    YAML

    @repo = FakeRepo.new
    @b2 = FakeB2.new
    Frijolero::App.repo = @repo
    Frijolero::App.b2 = @b2
  end

  def teardown
    restore_env('LEDGER_DIR', @previous_ledger_dir)
    Frijolero::App.repo = nil
    Frijolero::App.b2 = nil
    FileUtils.remove_entry(@dir)
  end

  def app
    Frijolero::App
  end

  def test_accounts_list_shows_open_before_closed
    get '/accounts'

    assert_equal 200, last_response.status
    assert_operator last_response.body.index('Activas'), :<, last_response.body.index('Cerradas')
    assert_operator last_response.body.index('BBVA TDC'), :<, last_response.body.index('Openbank')
  end

  # A lambda with output tags inside once rendered the whole page four times.
  def test_accounts_list_renders_each_account_once
    get '/accounts'

    assert_equal 1, last_response.body.scan('<h1>').size
    assert_equal 1, last_response.body.scan('>Openbank<').size
  end

  def test_account_page_titles_and_escapes_the_key
    get '/accounts/BBVA%20TDC'

    assert_includes last_response.body, '<title>BBVA TDC</title>'
  end

  def test_accounts_list_escapes_links_for_a_key_with_a_space
    get '/accounts'

    assert_includes last_response.body, '/accounts/BBVA%20TDC'
    assert_includes last_response.body, '/accounts/BBVA%20TDC/config'
    assert_includes last_response.body, '/rules/BBVA%20TDC'
  end

  def test_accounts_without_rules_get_no_rules_link
    get '/accounts'
    refute_includes last_response.body, '/rules/CETES'

    get '/accounts/CETES'
    refute_includes last_response.body, '/rules/CETES'
  end

  def test_accounts_list_links_to_the_full_yaml_editor
    get '/accounts'

    assert_includes last_response.body, '/accounts/yaml'
  end

  def test_accounts_yaml_editor_shows_the_current_file
    get '/accounts/yaml'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'AMEX:'
  end

  def test_saving_valid_accounts_yaml_writes_reloads_and_commits
    yaml = <<~YAML
      AMEX:
        beancount_account: "Liabilities:Amex"
      HSBC:
        beancount_account: "Assets:HSBC"
    YAML

    post '/accounts/yaml', content: yaml

    assert_equal 303, last_response.status
    assert Frijolero::Config.accounts.key?('HSBC')
    assert_equal ['accounts.yaml'], @repo.messages
  end

  def test_accounts_yaml_missing_beancount_account_is_rejected
    original = File.read(Frijolero::Config.accounts_file)

    post '/accounts/yaml', content: <<~YAML
      AMEX:
        beancount_account: "Liabilities:Amex"
      HSBC:
        nickname: "sin cuenta"
    YAML

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'HSBC'
    assert_equal original, File.read(Frijolero::Config.accounts_file)
    assert_empty @repo.messages
  end

  def test_account_page_lists_pdfs_newest_period_first
    @b2.entries = [
      { key: 'frijolero/accounts/BBVA TDC/BBVA TDC 2507.pdf', size: 120_000, last_modified: Time.new(2025, 8, 1) },
      { key: 'frijolero/accounts/BBVA TDC/BBVA TDC 2508.pdf', size: 130_000, last_modified: Time.new(2025, 9, 1) },
      { key: 'frijolero/accounts/BBVA TDC/AMEX 2508.pdf', size: 140_000, last_modified: Time.new(2025, 9, 1) }
    ]
    beancount_path = Frijolero::Config.statement_path('BBVA TDC', '2508', 'beancount')
    FileUtils.mkdir_p(File.dirname(beancount_path))
    File.write(beancount_path, '')

    get '/accounts/BBVA%20TDC'

    assert_equal 200, last_response.status
    assert_equal ['frijolero/accounts/BBVA TDC/'], @b2.prefixes
    assert_operator last_response.body.index('2508'), :<, last_response.body.index('2507')
    assert_includes last_response.body, '/statements/BBVA%20TDC/2508/pdf'
    assert_includes last_response.body, '/statements/BBVA%20TDC/2507/pdf'
    assert_includes last_response.body, '/statements/BBVA%20TDC/2508"'
    refute_includes last_response.body, '/statements/BBVA%20TDC/2507"'
    assert_includes last_response.body, 'sin procesar'
  end

  def test_account_page_with_no_pdfs
    @b2.entries = []

    get '/accounts/AMEX'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'No hay PDFs en B2'
  end

  def test_account_page_shows_a_b2_error
    @b2.error = 'boom'

    get '/accounts/AMEX'

    assert_equal 502, last_response.status
    assert_includes last_response.body, 'boom'
  end

  def test_unknown_account_page_404s
    get '/accounts/Nope'

    assert_equal 404, last_response.status
  end

  def test_account_config_editor_shows_only_that_accounts_block
    get '/accounts/BBVA%20TDC/config'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'BBVA TDC:'
    assert_includes last_response.body, 'kept for the classifier'
    refute_includes last_response.body, 'AMEX:'
    refute_includes last_response.body, 'Openbank:'
    assert_includes last_response.body, 'action="/accounts/BBVA%20TDC/config"'
  end

  def test_saving_a_valid_account_block_splices_it_back_and_commits
    block = <<~YAML
      BBVA TDC:
        beancount_account: "Liabilities:BBVA"
        description: "Tarjeta BBVA"
    YAML

    post '/accounts/BBVA%20TDC/config', content: block

    assert_equal 303, last_response.status
    assert_includes last_response.headers['Location'], '/accounts/BBVA%20TDC/config?saved=1'
    assert_equal 'Liabilities:BBVA', Frijolero::Config.accounts['BBVA TDC']['beancount_account']
    expected = <<~YAML
      # Account Configuration
      # maps keys to accounts

      AMEX:
        beancount_account: "Liabilities:Amex"
        openai_prompt_type: default
      # Alpaca statements, not the advisor PDF
      BBVA TDC:
        beancount_account: "Liabilities:BBVA"
        description: "Tarjeta BBVA"
      Openbank:
        closed: true
        beancount_account: "Assets:Openbank"
      CETES:
        beancount_account: "Assets:CETES"
        converter_type: cetes_directo
    YAML
    assert_equal expected, File.read(Frijolero::Config.accounts_file)
    assert_equal ['accounts BBVA TDC'], @repo.messages
  end

  def test_saving_an_invalid_account_block_is_rejected
    original = File.read(Frijolero::Config.accounts_file)

    post '/accounts/BBVA%20TDC/config', content: "BBVA TDC:\n  beancount_account: [unclosed"

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'YAML inválido'
    assert_equal original, File.read(Frijolero::Config.accounts_file)
    assert_empty @repo.messages
  end

  def test_saving_a_block_with_a_renamed_key_is_rejected
    original = File.read(Frijolero::Config.accounts_file)

    post '/accounts/BBVA%20TDC/config', content: "HSBC:\n  beancount_account: \"Assets:HSBC\"\n"

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'debe definir solo BBVA TDC'
    assert_equal original, File.read(Frijolero::Config.accounts_file)
  end

  def test_saving_a_block_without_beancount_account_is_rejected
    original = File.read(Frijolero::Config.accounts_file)

    post '/accounts/BBVA%20TDC/config', content: "BBVA TDC:\n  description: \"x\"\n"

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'falta beancount_account'
    assert_equal original, File.read(Frijolero::Config.accounts_file)
  end

  def test_unknown_account_config_404s
    get '/accounts/Nope/config'
    assert_equal 404, last_response.status

    post '/accounts/Nope/config', content: "Nope:\n  beancount_account: \"x\"\n"
    assert_equal 404, last_response.status
  end

  private

  def restore_env(key, previous_value)
    if previous_value.nil?
      ENV.delete(key)
    else
      ENV[key] = previous_value
    end
  end
end
