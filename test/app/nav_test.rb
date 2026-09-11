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
    '/' => 'Estados', '/upload' => 'Estados', '/jobs' => 'Estados',
    '/statements/AMEX' => 'Estados', '/statements/AMEX/2608' => 'Estados',
    '/accounts' => 'Cuentas', '/accounts/new' => 'Cuentas', '/accounts/AMEX/config' => 'Cuentas',
    '/rules/AMEX' => 'Cuentas'
  }.freeze

  HREFS = { 'Estados' => '/', 'Cuentas' => '/accounts', 'Reportes' => '/reports' }.freeze

  def test_topbar_marks_the_section_of_each_page
    SECTIONS.each do |path, section|
      get path

      assert_equal 200, last_response.status, path
      assert_includes last_response.body, %(<a href="#{HREFS[section]}" aria-current="page">#{section}</a>), path
      assert_equal 1, last_response.body.scan('aria-current="page"').size, path
    end
  end

  def test_topbar_has_three_sections_and_no_subir_or_jobs
    get '/'

    nav = last_response.body[%r{<nav aria-label="Secciones">.*?</nav>}m]
    assert_equal %w[Estados Cuentas Reportes], nav.scan(%r{>([^<]+)</a>}).flatten
  end

  def test_dashboard_is_periodos_with_bitacora_beside_it_and_the_upload_cta
    get '/'

    assert_includes last_response.body, '<h1>Periodos</h1>'
    assert_includes last_response.body, '<a href="/jobs">Bitácora</a>'
    assert_includes last_response.body, '<a class="button primary" href="/upload">Subir estado de cuenta</a>'
  end

  def test_jobs_page_is_bitacora_with_periodos_beside_it
    get '/jobs'

    assert_includes last_response.body, '<h1>Bitácora</h1>'
    assert_includes last_response.body, '<a href="/">Periodos</a>'
    assert_includes last_response.body, '<title>Bitácora</title>'
  end
end
