# frozen_string_literal: true

require 'test_helper'
require 'rack/test'

# The topbar's three sections and the secondary nav of Estados.
class NavTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  class FakeB2
    def list(_prefix) = []
  end

  def app = Frijolero::App

  def setup
    @dir = Dir.mktmpdir
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = @dir
    FileUtils.mkdir_p(File.join(@dir, 'config', 'rules'))
    FileUtils.mkdir_p(File.join(@dir, 'config', 'prompts', 'default'))
    File.write(File.join(@dir, 'config', 'accounts.yaml'), "AMEX:\n  beancount_account: \"Liabilities:Amex\"\n")
    File.write(File.join(@dir, 'config', 'rules', 'AMEX.yaml'), "start_with: {}\n")
    beancount = Frijolero::Config.statement_path('AMEX', '2608', 'beancount')
    FileUtils.mkdir_p(File.dirname(beancount))
    File.write(beancount, '')
    Frijolero::App.b2 = FakeB2.new
    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(@dir, 'jobs.jsonl'))
  end

  def teardown
    @previous_ledger_dir ? ENV['LEDGER_DIR'] = @previous_ledger_dir : ENV.delete('LEDGER_DIR')
    Frijolero::App.b2 = nil
    Frijolero::App.jobs = nil
    FileUtils.remove_entry(@dir)
  end

  SECTIONS = {
    '/' => 'Cuentas', '/upload' => 'Cuentas', '/jobs' => 'Cuentas', '/accounts/AMEX' => 'Cuentas',
    '/accounts/AMEX/2608' => 'Cuentas', '/accounts' => 'Cuentas', '/accounts/new' => 'Cuentas',
    '/accounts/AMEX/config' => 'Cuentas', '/accounts/AMEX/rules' => 'Cuentas'
  }.freeze

  HREFS = { 'Cuentas' => '/', 'Reportes' => '/reports' }.freeze

  def test_topbar_marks_the_section_of_each_page
    SECTIONS.each do |path, section|
      get path

      assert_equal 200, last_response.status, path
      assert_includes last_response.body, %(<a href="#{HREFS[section]}" aria-current="page">#{section}</a>), path
      assert_equal 1, last_response.body.scan('aria-current="page"').size, path
    end
  end

  def test_topbar_has_two_sections
    get '/'

    nav = last_response.body[%r{<nav aria-label="Secciones">.*?</nav>}m]
    assert_equal %w[Cuentas Reportes], nav.scan(%r{>([^<]+)</a>}).flatten
  end

  def test_dashboard_is_periodos_with_its_peers_beside_it_and_the_upload_cta
    get '/'

    assert_includes last_response.body, '<h1>Periodos</h1>'
    assert_includes last_response.body, '<a href="/jobs">Bitácora</a>'
    assert_includes last_response.body, '<a href="/accounts">Configuración</a>'
    assert_includes last_response.body, '<a class="button primary" href="/upload">Subir estado de cuenta</a>'
  end

  def test_jobs_page_is_bitacora_with_periodos_beside_it
    get '/jobs'

    assert_includes last_response.body, '<h1>Bitácora</h1>'
    assert_includes last_response.body, '<a href="/">Periodos</a>'
    assert_includes last_response.body, '<title>Bitácora</title>'
  end

  def test_accounts_list_is_configuracion_with_periodos_beside_it
    get '/accounts'

    assert_includes last_response.body, '<h1>Configuración</h1>'
    assert_includes last_response.body, '<a href="/">Periodos</a>'
    assert_includes last_response.body, '<title>Configuración</title>'
  end

  def test_other_pages_of_cuentas_show_the_title_row_as_links
    get '/accounts/new'

    assert_includes last_response.body, '<a href="/">Periodos</a>'
    assert_includes last_response.body, '<a href="/accounts">Configuración</a>'
    assert_includes last_response.body, '<h1>Nueva cuenta</h1>'
  end

  def test_upload_page_has_the_title_row_without_the_upload_button
    get '/upload'

    assert_includes last_response.body, '<a href="/jobs">Bitácora</a>'
    refute_includes last_response.body, 'href="/upload"'
  end

  TABS = { '/accounts/AMEX' => 'Estados', '/accounts/AMEX/2608' => 'Estados',
           '/accounts/AMEX/config' => 'Configuración', '/accounts/AMEX/rules' => 'Reglas' }.freeze
  TAB_HREFS = { 'Estados' => '/accounts/AMEX', 'Configuración' => '/accounts/AMEX/config',
                'Reglas' => '/accounts/AMEX/rules' }.freeze

  def test_account_pages_share_the_account_heading_and_tabs
    TABS.each do |path, tab|
      get path

      body = last_response.body
      assert_equal 200, last_response.status, path
      assert_equal ['<h1>AMEX</h1>'], body.scan(%r{<h1>.*?</h1>}), path
      assert_includes body, '<a href="/accounts">Configuración</a>', path
      assert_includes body, %(<a href="#{TAB_HREFS[tab]}" aria-current="true">#{tab}</a>), path
      assert_equal 2, body.scan('aria-current=').size, path
    end
  end

  def test_statement_page_has_the_period_as_subtitle
    get '/accounts/AMEX/2608'

    assert_includes last_response.body, '<h2>agosto 2026</h2>'
    assert_includes last_response.body, '<title>AMEX agosto 2026</title>'
  end

  def test_an_account_without_rules_has_no_reglas_tab
    File.write(File.join(@dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Assets:A"
        converter_type: fintual
    YAML

    get '/accounts/AMEX'

    refute_includes last_response.body, 'Reglas'
  end

  def test_a_period_route_never_captures_config_or_rules
    get '/accounts/AMEX/25-08'

    assert_equal 404, last_response.status
  end
end
