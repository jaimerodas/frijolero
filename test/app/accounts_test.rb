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

    assert_includes last_response.body, '/accounts/BBVA%20TDC"'
    assert_includes last_response.body, '/accounts/BBVA%20TDC/config'
    assert_includes last_response.body, '/accounts/BBVA%20TDC/rules'
  end

  def test_accounts_without_rules_get_no_rules_link
    get '/accounts'
    refute_includes last_response.body, '/accounts/CETES/rules'

    get '/accounts/CETES'
    refute_includes last_response.body, '/accounts/CETES/rules'
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
    assert_operator last_response.body.index('agosto 2025'), :<, last_response.body.index('julio 2025')
    assert_includes last_response.body, '/accounts/BBVA%20TDC/2508/pdf'
    assert_includes last_response.body, '/accounts/BBVA%20TDC/2507/pdf'
    assert_includes last_response.body, '/accounts/BBVA%20TDC/2508"'
    refute_includes last_response.body, '/accounts/BBVA%20TDC/2507"'
    assert_includes last_response.body, 'sin procesar'
  end

  def test_account_page_fills_missing_periods_up_to_the_last_closed_one
    @b2.entries = [
      { key: 'frijolero/accounts/AMEX/AMEX 2604.pdf', size: 120_000, last_modified: Time.new(2026, 5, 1) },
      { key: 'frijolero/accounts/AMEX/AMEX 2606.pdf', size: 130_000, last_modified: Time.new(2026, 7, 1) }
    ]

    Date.stub(:today, Date.new(2026, 9, 6)) { get '/accounts/AMEX' }

    body = last_response.body
    assert_equal 200, last_response.status
    months = Frijolero::App::MONTHS.join('|')
    expected = ['agosto 2026', 'julio 2026', 'junio 2026', 'mayo 2026', 'abril 2026']
    assert_equal expected, body.scan(/(?:#{months}) 20\d\d/)
    assert_equal 3, body.scan('falta').size
    assert_includes body, 'href="/upload"'
    refute_includes body, 'septiembre 2026'
    refute_includes body, 'marzo 2026'
  end

  def test_account_page_keeps_a_pdf_newer_than_the_last_closed_period
    @b2.entries = [{ key: 'frijolero/accounts/AMEX/AMEX 2609.pdf', size: 1, last_modified: Time.new(2026, 9, 5) }]

    Date.stub(:today, Date.new(2026, 9, 6)) { get '/accounts/AMEX' }

    assert_includes last_response.body, 'septiembre 2026'
    refute_includes last_response.body, 'falta'
  end

  def test_account_page_missing_periods_respect_the_cutoff_day
    File.write(File.join(@dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
        cutoff_day: 10
    YAML
    @b2.entries = [{ key: 'frijolero/accounts/AMEX/AMEX 2605.pdf', size: 1, last_modified: Time.new(2026, 6, 1) }]

    # Closed on Aug 10, so the newest statement is July's; August has not closed yet.
    Date.stub(:today, Date.new(2026, 9, 6)) { get '/accounts/AMEX' }

    assert_includes last_response.body, 'julio 2026'
    assert_includes last_response.body, 'junio 2026'
    refute_includes last_response.body, 'agosto 2026'
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

  # --- New account form ---

  def test_new_account_form_lists_the_prompt_types_except_classify
    make_prompt_types('default', 'bbva', 'classify')

    get '/accounts/new'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<option value="bbva">'
    assert_includes last_response.body, '<option value="default" selected>'
    refute_includes last_response.body, '<option value="classify">'
  end

  def test_accounts_list_links_to_the_new_account_form
    get '/accounts'

    assert_includes last_response.body, '/accounts/new'
  end

  def test_creating_an_account_appends_the_block_the_open_line_and_commits
    post '/accounts/new', new_account_params

    assert_equal 303, last_response.status
    assert_equal 'http://example.org/upload', last_response.headers['Location']

    yaml = File.read(File.join(@dir, 'config', 'accounts.yaml'))
    assert_includes yaml, '# kept for the classifier'
    assert_equal 'Assets:HSBC', Frijolero::Config.accounts['HSBC']['beancount_account']
    assert_equal 'Cuenta HSBC', Frijolero::Config.accounts['HSBC']['description']
    assert_equal 'default', Frijolero::Config.accounts['HSBC']['openai_prompt_type']
    assert_equal 15, Frijolero::Config.accounts['HSBC']['cutoff_day']
    assert_equal "2026-09-01 open Assets:HSBC\n", File.read(File.join(@dir, 'account_opens.beancount'))
    assert_equal ['cuenta HSBC'], @repo.messages
  end

  def test_creating_an_account_keeps_an_existing_open_line
    File.write(File.join(@dir, 'account_opens.beancount'), "2024-01-01 open Assets:BBVA\n2025-01-01 open Assets:HSBC\n")

    post '/accounts/new', new_account_params

    assert_equal 303, last_response.status
    assert_equal "2024-01-01 open Assets:BBVA\n2025-01-01 open Assets:HSBC\n",
                 File.read(File.join(@dir, 'account_opens.beancount'))
  end

  def test_creating_an_account_appends_the_open_line_after_a_file_without_a_final_newline
    File.write(File.join(@dir, 'account_opens.beancount'), '2024-01-01 open Assets:BBVA')

    post '/accounts/new', new_account_params

    assert_equal "2024-01-01 open Assets:BBVA\n2026-09-01 open Assets:HSBC\n",
                 File.read(File.join(@dir, 'account_opens.beancount'))
  end

  def test_creating_an_account_without_cutoff_day_leaves_it_out
    post '/accounts/new', new_account_params(cutoff_day: '')

    assert_equal 303, last_response.status
    refute Frijolero::Config.accounts['HSBC'].key?('cutoff_day')
  end

  def test_creating_an_account_with_an_existing_key_is_rejected
    post '/accounts/new', new_account_params(key: 'AMEX')

    assert_rejected 'AMEX ya existe'
  end

  def test_creating_an_account_whose_key_ends_in_a_period_is_rejected
    post '/accounts/new', new_account_params(key: 'HSBC 2026')

    assert_rejected 'La clave no puede terminar en cuatro dígitos'
  end

  def test_creating_an_account_with_a_bad_beancount_account_is_rejected
    post '/accounts/new', new_account_params(beancount_account: 'hsbc')

    assert_rejected 'Cuenta Beancount inválida'
  end

  def test_creating_an_account_with_a_bad_cutoff_day_is_rejected
    post '/accounts/new', new_account_params(cutoff_day: '32')

    assert_rejected 'El día de corte va de 1 a 31'
  end

  def test_creating_an_account_with_a_bad_date_is_rejected
    post '/accounts/new', new_account_params(opened_on: 'ayer')

    assert_rejected 'Fecha de apertura inválida'
  end

  def test_creating_an_account_with_an_unknown_prompt_type_is_rejected
    post '/accounts/new', new_account_params(openai_prompt_type: 'plata')

    assert_rejected 'Tipo de prompt desconocido'
  end

  private

  def make_prompt_types(*types)
    types.each { |type| FileUtils.mkdir_p(File.join(@dir, 'config', 'prompts', type)) }
  end

  def new_account_params(**overrides)
    make_prompt_types('default', 'bbva')
    { key: 'HSBC', description: 'Cuenta HSBC', beancount_account: 'Assets:HSBC', openai_prompt_type: 'default',
      cutoff_day: '15', opened_on: '2026-09-01' }.merge(overrides)
  end

  def assert_rejected(message)
    assert_equal 422, last_response.status
    assert_includes last_response.body, message
    refute Frijolero::Config.accounts.key?('HSBC')
    refute File.exist?(File.join(@dir, 'account_opens.beancount'))
    assert_empty @repo.messages
  end

  def restore_env(key, previous_value)
    if previous_value.nil?
      ENV.delete(key)
    else
      ENV[key] = previous_value
    end
  end
end
