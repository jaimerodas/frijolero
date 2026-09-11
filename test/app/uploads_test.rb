# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'fileutils'
require 'stringio'

class UploadsTest < Minitest::Test
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
    attr_accessor :put_error

    def initialize(order = [])
      @order = order
      @calls = []
    end

    def presigned_url(key, **)
      @calls << key
      "https://b2.example/#{key.gsub(' ', '%20')}?sig=1"
    end

    def put(key, _path, **)
      raise Frijolero::B2::Error.new(@put_error, status: 500) if @put_error

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
      raise Frijolero::LedgerRepo::Error, @pull_error if @pull_error
    end

    # The real LedgerRepo answers whether it pushed anything; the job ignores it.
    def commit_and_push(message)
      @order << :commit_and_push
      @messages << message
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = @dir
    FileUtils.mkdir_p(File.join(@dir, 'config'))
    File.write(File.join(@dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
      BBVA:
        beancount_account: "Assets:BBVA"
        cutoff_day: 31
      CETES:
        beancount_account: "Assets:CETES"
        converter_type: cetes_directo
    YAML
    FileUtils.mkdir_p(File.join(@dir, 'config', 'prompts'))
    FileUtils.cp_r(fixture_path('prompts/default'), File.join(@dir, 'config', 'prompts', 'default'))
    FileUtils.cp_r(template_path('prompts/classify'),
                   File.join(@dir, 'config', 'prompts', 'classify'))
    File.write(File.join(@dir, 'transactions.beancount'), '')

    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(@dir, 'jobs.jsonl'))
    @client = FakeClient.new
    @order = []
    @b2 = FakeB2.new(@order)
    @repo = FakeRepo.new(@order)
    Frijolero::App.client = @client
    Frijolero::App.b2 = @b2
    Frijolero::App.repo = @repo
    Frijolero::Log.sink = StringIO.new
  end

  def teardown
    restore_env('LEDGER_DIR', @previous_ledger_dir)
    Frijolero::App.jobs = nil
    Frijolero::App.client = nil
    Frijolero::App.b2 = nil
    Frijolero::App.repo = nil
    Frijolero::Log.sink = $stdout
    FileUtils.remove_entry(@dir)
  end

  def app
    Frijolero::App
  end

  def test_dashboard_shows_accounts_and_periods
    get '/'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'AMEX'
    assert_includes last_response.body, 'BBVA'
    Frijolero::Dashboard.new.periods.each { |period| assert_includes last_response.body, app.new!.period_name(period) }
  end

  def test_dashboard_shows_the_cutoff_day_of_each_account
    get '/'

    assert_includes last_response.body, 'fin de mes'
  end

  def test_the_job_records_the_cutoff_day_from_the_confirmed_period_end
    token = upload_and_extract_token('AMEX 2508.pdf')
    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, overwrite: '0', period_end: '2025-08-03'

    Frijolero::App.jobs.work_one

    assert_equal 3, Frijolero::Config.accounts['AMEX']['cutoff_day']
    assert_equal 31, Frijolero::Config.accounts['BBVA']['cutoff_day']
  end

  def test_dashboard_renders_the_shared_head
    get '/'

    assert_includes last_response.body, '<title>Frijolero</title>'
    assert_includes last_response.body, 'fonts.googleapis.com/css2'
    assert_equal 1, last_response.body.scan('<meta charset').size
  end

  def test_dashboard_links_to_jobs_accounts_and_rules
    get '/'

    assert_includes last_response.body, 'href="/jobs"'
    assert_includes last_response.body, 'href="/accounts"'
    assert_includes last_response.body, 'href="/rules/AMEX"'
    refute_includes last_response.body, 'href="/rules/CETES"'
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

  def test_a_filename_with_accents_renders_the_confirm_page
    @client.classification = { 'account' => 'BBVA', 'period_start' => '2026-07-24', 'period_end' => '2026-08-23' }

    post '/upload', pdf: pdf_upload('estado.pdf', name: 'Estado de cuenta – agosto.pdf')

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Estado de cuenta – agosto.pdf'
  end

  def test_unknown_filename_classifies_via_openai
    @client.classification = { 'account' => 'BBVA', 'period_start' => '2026-07-24', 'period_end' => '2026-08-23' }

    post '/upload', pdf: pdf_upload('estado.pdf')

    assert_match(/value="BBVA"\s+selected/, last_response.body)
    assert_includes last_response.body, 'value="2608"'
    assert_includes last_response.body, '2026-07-24 a 2026-08-23'
    assert_match(/name="file_id" value="file-1"/, last_response.body)
    assert_match(/name="period_end" value="2026-08-23"/, last_response.body)
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
    job = Frijolero::App.jobs.find(job_id)
    assert_equal 'AMEX 2508', job.label

    Frijolero::App.jobs.work_one

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

    Frijolero::App.jobs.work_one

    assert_equal %i[pull put commit_and_push], @order
    assert_equal ['AMEX 2508'], @repo.messages
    assert_equal ['frijolero/accounts/AMEX/AMEX 2508.pdf'], @b2.calls
  end

  # A clone that cannot pull is a clone that cannot push either, so there is no point
  # paying OpenAI for the extraction.
  def test_a_failed_pull_fails_the_job_before_the_extraction
    @repo.pull_error = 'offline'
    token = upload_and_extract_token('AMEX 2508.pdf')
    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, overwrite: '0'
    job_id = last_response.location[%r{/jobs/(.+)\z}, 1]

    Frijolero::App.jobs.work_one

    job = Frijolero::App.jobs.find(job_id)
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
    Frijolero::App.jobs.work_one

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

  def test_confirm_page_offers_to_save_only_the_pdf
    upload_and_extract_token('AMEX 2508.pdf')

    assert_includes last_response.body, 'formaction="/upload/backup"'
  end

  # For a statement whose .beancount already exists: the PDF lands in B2 and nothing else moves.
  def test_backup_puts_the_pdf_in_b2_without_a_job
    token = upload_and_extract_token('AMEX 2508.pdf')

    post '/upload/backup', account: 'AMEX', period: '2508', token: token

    assert_equal 303, last_response.status
    assert_equal '/statements/AMEX', URI(last_response.location).path
    assert_equal ['frijolero/accounts/AMEX/AMEX 2508.pdf'], @b2.calls
    assert_equal [:put], @order
    assert_empty Frijolero::App.jobs.all
    assert_empty @client.uploaded
    refute Dir.exist?(File.join(Frijolero::Config.incoming_dir, token))
  end

  def test_backup_keeps_the_upload_when_b2_fails
    token = upload_and_extract_token('AMEX 2508.pdf')
    @b2.put_error = 'boom'

    post '/upload/backup', account: 'AMEX', period: '2508', token: token

    assert_equal 502, last_response.status
    assert_includes last_response.body, 'boom'
    assert Dir.exist?(File.join(Frijolero::Config.incoming_dir, token))
  end

  def test_backup_rejects_unknown_account
    token = upload_and_extract_token('AMEX 2508.pdf')

    post '/upload/backup', account: 'HSBC', period: '2508', token: token

    assert_equal 422, last_response.status
    assert_empty @b2.calls
  end

  def test_failed_statement_keeps_the_upload_for_a_retry
    beancount_path = Frijolero::Config.statement_path('AMEX', '2508', 'beancount')
    FileUtils.mkdir_p(File.dirname(beancount_path))
    File.write(beancount_path, '')

    token = upload_and_extract_token('AMEX 2508.pdf')
    post '/upload/confirm', account: 'AMEX', period: '2508', token: token, overwrite: '0'
    job_id = last_response.location[%r{/jobs/(.+)\z}, 1]

    Frijolero::App.jobs.work_one

    job = Frijolero::App.jobs.find(job_id)
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

    Frijolero::App.jobs.work_one
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
    Frijolero::App.jobs.work_one

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
    assert_equal 'https://b2.example/frijolero/accounts/AMEX/AMEX%202508.pdf?sig=1', last_response.headers['Location']
    assert_equal ['frijolero/accounts/AMEX/AMEX 2508.pdf'], Frijolero::App.b2.calls
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

    get '/statements/BBVA%20TDC/2508/pdf'

    assert_equal 302, last_response.status
    assert_equal 'https://b2.example/frijolero/accounts/BBVA%20TDC/BBVA%20TDC%202508.pdf?sig=1',
                 last_response.headers['Location']
    assert_equal ['frijolero/accounts/BBVA TDC/BBVA TDC 2508.pdf'], Frijolero::App.b2.calls
  end

  def test_pdf_download_returns_404_for_unknown_account
    get '/statements/UNKNOWN/2508/pdf'

    assert_equal 404, last_response.status
    assert_empty Frijolero::App.b2.calls
  end

  def test_pdf_download_returns_404_for_invalid_period
    get '/statements/AMEX/25-08/pdf'

    assert_equal 404, last_response.status
    assert_empty Frijolero::App.b2.calls
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
