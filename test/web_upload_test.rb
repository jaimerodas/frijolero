# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'fileutils'
require 'stringio'

class WebUploadTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  class FakeClient
    attr_reader :uploaded, :deleted, :extractions
    attr_accessor :classification

    def initialize
      @uploaded = []
      @deleted = []
      @extractions = []
      @classification = { 'account' => 'unknown', 'period_start' => nil, 'period_end' => nil }
    end

    def upload_file(path)
      @uploaded << path
      'file-1'
    end

    def extract_transactions(_file_id, spec)
      name = spec['format']['name']
      @extractions << name
      return @classification if name == 'statement_classification'

      { 'transactions' => [{ 'date' => '2025-08-03', 'description' => 'X', 'amount' => -10.0, 'currency' => 'MXN' }] }
    end

    def delete_file(id)
      @deleted << id
    end
  end

  # The bucket and the clone. Both append to one shared `order` array, which is what
  # lets a test assert that the PDF reached B2 between the pull and the push.
  class FakeB2
    attr_reader :calls

    def initialize(order = [])
      @order = order
      @calls = []
    end

    def presigned_url(key, **)
      @calls << key
      "https://b2.example/#{key.gsub(' ', '%20')}?sig=1"
    end

    def put(key, _path, **)
      @order << :put
      @calls << key
    end
  end

  class FakeRepo
    attr_reader :messages
    attr_accessor :pull_error

    def initialize(order = [])
      @order = order
      @messages = []
    end

    def pull
      @order << :pull
      raise Frijolero::Web::LedgerRepo::Error, @pull_error if @pull_error
    end

    # The real LedgerRepo answers whether it pushed anything; the job ignores it.
    def commit_and_push(message)
      @order << :commit_and_push
      @messages << message
    end
  end

  def setup
    @previous_rack_env = ENV.fetch('RACK_ENV', nil)
    ENV['RACK_ENV'] = 'test'
    # See the comment in web_app_test.rb: this must load after RACK_ENV is set.
    require 'frijolero/web/app'

    @dir = Dir.mktmpdir
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = @dir
    FileUtils.mkdir_p(File.join(@dir, 'config'))
    File.write(File.join(@dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
      BBVA:
        beancount_account: "Assets:BBVA"
    YAML
    FileUtils.mkdir_p(File.join(@dir, 'config', 'prompts'))
    FileUtils.cp_r(fixture_path('prompts/default'), File.join(@dir, 'config', 'prompts', 'default'))
    FileUtils.cp_r(File.expand_path('../lib/frijolero/templates/prompts/classify', __dir__),
                   File.join(@dir, 'config', 'prompts', 'classify'))
    File.write(File.join(@dir, 'transactions.beancount'), '')
    Frijolero::Config.reload!

    Frijolero::Web::App.jobs = Frijolero::Web::Jobs.new(log_path: File.join(@dir, 'jobs.jsonl'))
    @client = FakeClient.new
    @order = []
    @b2 = FakeB2.new(@order)
    @repo = FakeRepo.new(@order)
    Frijolero::Web::App.client = @client
    Frijolero::Web::App.b2 = @b2
    Frijolero::Web::App.repo = @repo
    Frijolero::UI.sink = StringIO.new
  end

  def teardown
    restore_env('RACK_ENV', @previous_rack_env)
    restore_env('LEDGER_DIR', @previous_ledger_dir)
    Frijolero::Config.reload!
    Frijolero::Web::App.jobs = nil
    Frijolero::Web::App.client = nil
    Frijolero::Web::App.b2 = nil
    Frijolero::Web::App.repo = nil
    Frijolero::UI.sink = $stdout
    Frijolero::UI.auto_accept = false
    FileUtils.remove_entry(@dir)
  end

  def app
    Frijolero::Web::App
  end

  def test_dashboard_shows_accounts_and_periods
    get '/'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'AMEX'
    assert_includes last_response.body, 'BBVA'
    Frijolero::Web::Dashboard.new.periods.each { |period| assert_includes last_response.body, period }
  end

  def test_upload_form_has_pdf_field
    get '/upload'

    assert_includes last_response.body, 'name="pdf"'
  end

  def test_known_filename_skips_classification_and_prefills_it
    post '/upload', pdf: pdf_upload('AMEX 2508.pdf')

    assert_equal 200, last_response.status
    assert_match(/value="AMEX"\s+selected/, last_response.body)
    assert_includes last_response.body, 'value="2508"'
    assert_empty @client.uploaded
    assert(Dir.glob(File.join(Frijolero::Config.incoming_dir, '*', '*')).any?)
  end

  def test_unknown_filename_classifies_via_openai
    @client.classification = { 'account' => 'BBVA', 'period_start' => '2026-07-24', 'period_end' => '2026-08-23' }

    post '/upload', pdf: pdf_upload('estado.pdf')

    assert_match(/value="BBVA"\s+selected/, last_response.body)
    assert_includes last_response.body, 'value="2608"'
    assert_includes last_response.body, '2026-07-24 a 2026-08-23'
    assert_match(/name="file_id" value="file-1"/, last_response.body)
  end

  def test_unknown_account_selects_nothing_but_keeps_the_period
    @client.classification = { 'account' => 'unknown', 'period_start' => '2026-07-24', 'period_end' => '2026-08-23' }

    post '/upload', pdf: pdf_upload('estado.pdf')

    refute_match(/selected/, last_response.body)
    assert_includes last_response.body, 'value="2608"'
  end

  def test_upload_without_a_file_is_rejected
    post '/upload'

    assert_equal 422, last_response.status
  end

  def test_upload_of_a_non_pdf_is_rejected
    post '/upload', pdf: pdf_upload('foto.png', name: 'foto.png')

    assert_equal 422, last_response.status
  end

  def test_confirm_happy_path_enqueues_and_runs_the_job
    token = upload_and_extract_token('AMEX 2508.pdf')

    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, file_id: '', overwrite: '0'

    assert_equal 303, last_response.status
    job_id = last_response.location[%r{/jobs/(.+)\z}, 1]
    job = Frijolero::Web::App.jobs.find(job_id)
    assert_equal 'AMEX 2508', job.label

    Frijolero::Web::App.jobs.work_one

    assert_equal 'ok', job.status
    assert File.exist?(Frijolero::Config.statement_path('AMEX', '2508', 'beancount'))
    assert_includes File.read(Frijolero::Config.main_file), 'include'
    refute Dir.exist?(File.join(Frijolero::Config.incoming_dir, token))
  end

  # The order is the durability property: pull before anything is written, the PDF in
  # B2 before the extraction is paid for, the push only once a statement landed.
  def test_the_job_pulls_saves_the_pdf_and_pushes_in_that_order
    token = upload_and_extract_token('AMEX 2508.pdf')
    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, overwrite: '0'

    Frijolero::Web::App.jobs.work_one

    assert_equal %i[pull put commit_and_push], @order
    assert_equal ['AMEX 2508'], @repo.messages
    assert_equal ['accounts/AMEX/AMEX 2508.pdf'], @b2.calls
  end

  # A clone that cannot pull is a clone that cannot push either, so there is no point
  # paying OpenAI for the extraction.
  def test_a_failed_pull_fails_the_job_before_the_extraction
    @repo.pull_error = 'offline'
    token = upload_and_extract_token('AMEX 2508.pdf')
    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, overwrite: '0'
    job_id = last_response.location[%r{/jobs/(.+)\z}, 1]

    Frijolero::Web::App.jobs.work_one

    job = Frijolero::Web::App.jobs.find(job_id)
    assert_equal 'failed', job.status
    assert_includes job.error, 'offline'
    assert_empty @client.extractions
    assert Dir.exist?(File.join(Frijolero::Config.incoming_dir, token))
  end

  def test_a_failed_statement_is_never_pushed
    beancount_path = Frijolero::Config.statement_path('AMEX', '2508', 'beancount')
    FileUtils.mkdir_p(File.dirname(beancount_path))
    File.write(beancount_path, '')

    token = upload_and_extract_token('AMEX 2508.pdf')
    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, overwrite: '0'
    Frijolero::Web::App.jobs.work_one

    refute_includes @order, :commit_and_push
    assert_empty @repo.messages
  end

  def test_confirm_rejects_bad_period
    token = upload_and_extract_token('AMEX 2508.pdf')

    post '/upload/confirm', account: 'AMEX', period: '25-08', token: token, overwrite: '0'

    assert_equal 422, last_response.status
  end

  def test_confirm_rejects_unknown_account
    token = upload_and_extract_token('AMEX 2508.pdf')

    post '/upload/confirm', account: 'HSBC', period: '2508', token: token, overwrite: '0'

    assert_equal 422, last_response.status
  end

  def test_confirm_rejects_a_token_with_no_directory
    post '/upload/confirm', account: 'AMEX', period: '2508', token: 'a' * 16, overwrite: '0'

    assert_equal 422, last_response.status
  end

  def test_failed_statement_keeps_the_upload_for_a_retry
    beancount_path = Frijolero::Config.statement_path('AMEX', '2508', 'beancount')
    FileUtils.mkdir_p(File.dirname(beancount_path))
    File.write(beancount_path, '')

    token = upload_and_extract_token('AMEX 2508.pdf')
    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, overwrite: '0'
    job_id = last_response.location[%r{/jobs/(.+)\z}, 1]

    Frijolero::Web::App.jobs.work_one

    job = Frijolero::Web::App.jobs.find(job_id)
    assert_equal 'failed', job.status
    assert_includes job.error, 'overwrite_declined'
    assert Dir.exist?(File.join(Frijolero::Config.incoming_dir, token))
  end

  def test_job_page_refreshes_while_running_and_links_when_done
    token = upload_and_extract_token('AMEX 2508.pdf')
    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, overwrite: '0'
    job_id = last_response.location[%r{/jobs/(.+)\z}, 1]

    get "/jobs/#{job_id}"
    assert_includes last_response.body, 'http-equiv="refresh"'

    Frijolero::Web::App.jobs.work_one
    get "/jobs/#{job_id}"
    refute_includes last_response.body, 'http-equiv="refresh"'
    assert_includes last_response.body, '/statements/AMEX/2508'
  end

  def test_job_page_shows_the_error_for_a_failed_job
    beancount_path = Frijolero::Config.statement_path('AMEX', '2508', 'beancount')
    FileUtils.mkdir_p(File.dirname(beancount_path))
    File.write(beancount_path, '')

    token = upload_and_extract_token('AMEX 2508.pdf')
    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, overwrite: '0'
    job_id = last_response.location[%r{/jobs/(.+)\z}, 1]
    Frijolero::Web::App.jobs.work_one

    get "/jobs/#{job_id}"

    assert_includes last_response.body, 'overwrite_declined'
  end

  def test_job_page_404s_for_an_unknown_id
    get '/jobs/nope'

    assert_equal 404, last_response.status
  end

  def test_jobs_index_lists_the_label
    token = upload_and_extract_token('AMEX 2508.pdf')
    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, overwrite: '0'

    get '/jobs'

    assert_includes last_response.body, 'AMEX 2508'
  end

  def test_pdf_download_redirects_to_b2_presigned_url
    get '/statements/AMEX/2508/pdf'

    assert_equal 302, last_response.status
    assert_equal 'https://b2.example/accounts/AMEX/AMEX%202508.pdf?sig=1', last_response.headers['Location']
    assert_equal ['accounts/AMEX/AMEX 2508.pdf'], Frijolero::Web::App.b2.calls
  end

  def test_pdf_download_with_account_containing_space
    # Add BBVA TDC to accounts
    accounts_file = File.join(@dir, 'config', 'accounts.yaml')
    File.write(accounts_file, <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
      BBVA TDC:
        beancount_account: "Assets:BBVA"
    YAML
    Frijolero::Config.reload!

    get '/statements/BBVA%20TDC/2508/pdf'

    assert_equal 302, last_response.status
    assert_equal 'https://b2.example/accounts/BBVA%20TDC/BBVA%20TDC%202508.pdf?sig=1', last_response.headers['Location']
    assert_equal ['accounts/BBVA TDC/BBVA TDC 2508.pdf'], Frijolero::Web::App.b2.calls
  end

  def test_pdf_download_returns_404_for_unknown_account
    get '/statements/UNKNOWN/2508/pdf'

    assert_equal 404, last_response.status
    assert_empty Frijolero::Web::App.b2.calls
  end

  def test_pdf_download_returns_404_for_invalid_period
    get '/statements/AMEX/25-08/pdf'

    assert_equal 404, last_response.status
    assert_empty Frijolero::Web::App.b2.calls
  end

  private

  def pdf_upload(filename, name: nil)
    path = File.join(@dir, "upload-#{rand(1_000_000)}-#{filename}")
    File.write(path, "%PDF-1.4\n")
    Rack::Test::UploadedFile.new(path, 'application/pdf', original_filename: name || filename)
  end

  def upload_and_extract_token(filename)
    post '/upload', pdf: pdf_upload(filename)
    last_response.body[/name="token" value="([^"]*)"/, 1]
  end

  def restore_env(key, previous_value)
    if previous_value.nil?
      ENV.delete(key)
    else
      ENV[key] = previous_value
    end
  end
end
