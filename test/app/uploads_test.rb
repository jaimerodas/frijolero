# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'fileutils'
require 'stringio'

class UploadsTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  class FakeClient
    attr_reader :extractions
    attr_accessor :classification, :extract_error

    def initialize
      @extractions = []
      @classification = { 'account' => 'unknown', 'period_start' => nil, 'period_end' => nil }
    end

    def extract(_path, spec)
      name = spec['format']['name']
      @extractions << name
      return @classification if name == 'statement_classification'
      raise @extract_error if @extract_error

      { 'transactions' => [{ 'date' => '2025-08-03', 'description' => 'X', 'amount' => -10.0, 'currency' => 'MXN' }] }
    end
  end

  # The bucket and the clone. Both append to one shared `order` array, which is what
  # lets a test assert that the PDF reached S3 between the pull and the push.
  class FakeS3
    attr_reader :calls
    attr_accessor :put_error

    def initialize(order = [])
      @order = order
      @calls = []
    end

    def presigned_url(key, **)
      @calls << key
      "https://s3.example/#{key.gsub(' ', '%20')}?sig=1"
    end

    def put(key, _path)
      raise Frijolero::S3::Error.new(@put_error, status: 500) if @put_error

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
    File.write(File.join(@dir, 'main.beancount'), '')

    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(@dir, 'jobs.jsonl'))
    @incoming = File.join(@dir, 'incoming')
    Frijolero::App.inbox = Frijolero::Inbox.new(@incoming)
    @worker = Frijolero::Inbox::Worker.new(Frijolero::App.inbox) { |pdf| Frijolero::App.classify(pdf) }
    Frijolero::App.inbox_worker = @worker
    @client = FakeClient.new
    @order = []
    @s3 = FakeS3.new(@order)
    @repo = FakeRepo.new(@order)
    Frijolero::App.client = @client
    Frijolero::App.s3 = @s3
    Frijolero::App.repo = @repo
    Frijolero::Log.sink = StringIO.new
  end

  def teardown
    restore_env('LEDGER_DIR', @previous_ledger_dir)
    Frijolero::App.jobs = nil
    Frijolero::App.inbox = nil
    Frijolero::App.inbox_worker = nil
    Frijolero::App.client = nil
    Frijolero::App.s3 = nil
    Frijolero::App.repo = nil
    Frijolero::Log.sink = $stdout
    FileUtils.remove_entry(@dir)
  end

  def app
    Frijolero::App
  end

  def test_without_accounts_every_upload_route_goes_to_the_new_account_form_and_never_calls_openai
    File.delete(File.join(@dir, 'config', 'accounts.yaml'))

    get '/upload'

    assert_equal 303, last_response.status
    assert_equal '/accounts/new', URI(last_response.location).path

    post '/upload', pdf: [pdf_upload('AMEX 2508.pdf')]

    assert_equal 303, last_response.status
    assert_equal '/accounts/new', URI(last_response.location).path
    assert_empty @client.extractions
    assert_empty Dir.glob(File.join(@incoming, '*'))
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
    assert_includes last_response.body, 'href="/accounts/AMEX/rules"'
    refute_includes last_response.body, 'href="/accounts/CETES/rules"'
  end

  def test_dashboard_points_to_the_uploads_waiting_in_the_inbox
    get '/'
    refute_includes last_response.body, 'por confirmar'

    api_upload('estado.pdf')
    get '/'

    assert_includes last_response.body, '<a class="status missing" href="/inbox">1 por confirmar</a>'
  end

  # The web form: one or more PDFs into the Bandeja, like the Shortcut.
  def test_upload_form_takes_several_pdfs
    get '/upload'

    assert_includes last_response.body, 'name="pdf[]"'
    assert_includes last_response.body, ' multiple'
  end

  def test_a_web_upload_of_several_pdfs_goes_to_the_inbox_before_the_model
    post '/upload', pdf: [pdf_upload('AMEX 2508.pdf'), pdf_upload('estado.pdf')]

    assert_equal 303, last_response.status
    assert_equal '/inbox', URI(last_response.location).path
    assert_equal ['AMEX 2508.pdf', 'estado.pdf'], Frijolero::App.inbox.items.map(&:filename).sort
    assert_empty @client.extractions
  end

  def test_a_web_upload_queues_the_classification
    @client.classification = { 'account' => 'BBVA', 'period_start' => '2026-07-24', 'period_end' => '2026-08-23' }
    post '/upload', pdf: [pdf_upload('estado.pdf')]

    @worker.work_one

    assert_equal %w[BBVA 2608], Frijolero::App.inbox.items.first.answer.values_at('account', 'period')
  end

  def test_a_filename_with_accents_shows_in_the_inbox
    post '/upload', pdf: [pdf_upload('estado.pdf', name: 'Estado de cuenta – agosto.pdf')]

    get '/inbox'

    assert_includes last_response.body, 'Estado de cuenta – agosto.pdf'
  end

  def test_upload_without_a_file_is_rejected
    post '/upload'

    assert_equal 422, last_response.status
  end

  def test_upload_of_a_non_pdf_is_rejected
    post '/upload', pdf: [pdf_upload('foto.png', name: 'foto.png')]

    assert_equal 422, last_response.status
  end

  def test_one_non_pdf_among_several_saves_nothing
    post '/upload', pdf: [pdf_upload('AMEX 2508.pdf'), pdf_upload('foto.png', name: 'foto.png')]

    assert_equal 422, last_response.status
    assert_empty Frijolero::App.inbox.items
  end

  def test_upload_page_without_a_model_key_says_so_before_the_upload
    Frijolero::App.client = nil
    without_env('OPENAI_API_KEY') { get '/upload' }

    assert_includes last_response.body, 'OPENAI_API_KEY'
    assert_includes last_response.body, 'Clave YYMM.pdf'
  end

  def test_upload_page_with_a_model_key_has_no_warning
    get '/upload'

    refute_includes last_response.body, 'OPENAI_API_KEY'
  end

  def test_the_buttons_that_wait_say_so
    get '/upload'
    assert_includes last_response.body, 'data-busy="Subiendo…"'

    classified('AMEX 2508.pdf')
    get '/inbox'
    assert_includes last_response.body, 'data-busy="Procesando…"'
    assert_includes last_response.body, 'data-busy="Guardando…"'
  end

  # The Shortcut's way in. Login checks the token; App never sees it.
  def test_api_upload_saves_the_pdf_and_answers_before_the_model
    post '/api/upload', pdf: pdf_upload('estado.pdf')

    assert_equal 202, last_response.status
    assert_equal 'application/json', last_response.media_type
    assert_equal({ 'inbox' => 'http://example.org/inbox' }, JSON.parse(last_response.body))
    assert_equal ['estado.pdf'], Frijolero::App.inbox.items.map(&:filename)
    assert_empty @client.extractions
  end

  def test_api_upload_queues_the_classification
    @client.classification = { 'account' => 'BBVA', 'period_start' => '2026-07-24', 'period_end' => '2026-08-23' }
    post '/api/upload', pdf: pdf_upload('estado.pdf')

    @worker.work_one

    answer = Frijolero::App.inbox.items.first.answer
    assert_equal %w[BBVA 2608 2026-08-23], answer.values_at('account', 'period', 'period_end')
  end

  def test_api_upload_of_a_non_pdf_answers_with_a_json_error
    post '/api/upload', pdf: pdf_upload('foto.png', name: 'foto.png')

    assert_equal 422, last_response.status
    assert_equal({ 'error' => 'Sube un PDF' }, JSON.parse(last_response.body))
    assert_empty Frijolero::App.inbox.items
  end

  def test_api_upload_without_accounts_saves_nothing
    File.delete(File.join(@dir, 'config', 'accounts.yaml'))

    post '/api/upload', pdf: pdf_upload('estado.pdf')

    assert_equal 422, last_response.status
    assert_includes JSON.parse(last_response.body)['error'], 'cuenta'
    assert_empty Frijolero::App.inbox.items
  end

  # Classification.
  def test_a_known_filename_needs_no_model
    Frijolero::App.client = nil
    without_env('OPENAI_API_KEY') { classified('AMEX 2508.pdf') }

    assert_equal %w[AMEX 2508], Frijolero::App.inbox.items.first.answer.values_at('account', 'period')
  end

  def test_the_missing_variable_is_the_one_of_the_provider_in_use
    Frijolero::App.client = nil

    with_env('LLM_PROVIDER' => 'anthropic', 'ANTHROPIC_API_KEY' => nil) { classified('estado.pdf') }

    assert_equal({ 'error' => 'Falta ANTHROPIC_API_KEY' }, Frijolero::App.inbox.items.first.answer)
  end

  # The Bandeja page.
  def test_an_empty_inbox_says_where_uploads_come_from
    get '/inbox'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Nada por confirmar'
    refute_includes last_response.body, '<form method="post" action="/inbox/process"'
  end

  def test_an_upload_being_classified_shows_and_the_page_refreshes
    api_upload('estado.pdf')

    get '/inbox'

    assert_includes last_response.body, 'estado.pdf'
    assert_includes last_response.body, '<span class="status running">clasificando</span>'
    assert_includes last_response.body, 'http-equiv="refresh"'
  end

  def test_a_classified_upload_is_ready_with_its_guess_filled_in
    @client.classification = { 'account' => 'BBVA', 'period_start' => '2026-07-24', 'period_end' => '2026-08-23' }
    token = classified('estado.pdf')

    get '/inbox'

    assert_includes last_response.body, '<span class="status ok">listo</span>'
    assert_match(/value="BBVA"\s+selected/, last_response.body)
    assert_includes last_response.body, %(name="period[#{token}]" value="2608")
    assert_includes last_response.body, '2026-07-24 a 2026-08-23'
    assert_includes last_response.body, %(name="tokens" value="#{token}" data-busy="Procesando…">Procesar los listos)
    refute_includes last_response.body, 'http-equiv="refresh"'
  end

  def test_an_unknown_account_selects_nothing_but_keeps_the_period
    @client.classification = { 'account' => 'unknown', 'period_start' => '2026-07-24', 'period_end' => '2026-08-23' }
    token = classified('estado.pdf')

    get '/inbox'

    assert_includes last_response.body, '<span class="status missing">sin identificar</span>'
    refute_match(/selected/, last_response.body)
    assert_includes last_response.body, %(name="period[#{token}]" value="2608")
  end

  def test_only_the_ready_uploads_go_into_process_the_ready_ones
    ready = classified('AMEX 2508.pdf')
    also_ready = classified('BBVA 2508.pdf')
    unknown = classified('estado.pdf')

    get '/inbox'

    assert_includes last_response.body, %(name="tokens" value="#{ready} #{also_ready}")
    assert_includes last_response.body, '<span class="status missing">sin identificar</span>'
    assert_includes last_response.body, %(name="tokens" value="#{unknown}")
  end

  def test_an_upload_of_an_existing_statement_offers_to_overwrite
    statement('AMEX', '2508')
    token = classified('AMEX 2508.pdf')

    get '/inbox'

    assert_includes last_response.body, '<span class="status missing">ya existe</span>'
    assert_includes last_response.body, %(name="overwrite[#{token}]" value="1")
    refute_includes last_response.body, 'Procesar los listos'
  end

  def test_two_uploads_of_one_statement_are_both_marked
    classified('AMEX 2508.pdf')
    classified('AMEX 2508.pdf')

    get '/inbox'

    assert_equal 2, last_response.body.scan('<span class="status missing">repetido</span>').size
    refute_includes last_response.body, 'Procesar los listos'
  end

  def test_a_classifier_error_shows_with_its_message_and_offers_only_to_save_the_pdf
    Frijolero::App.client = nil
    without_env('OPENAI_API_KEY') do
      classified('estado.pdf')
      get '/inbox'
    end

    assert_includes last_response.body, '<span class="status failed">no se clasificó</span>'
    assert_includes last_response.body, 'Falta OPENAI_API_KEY'
    refute_includes last_response.body, '>Procesar<'
    assert_includes last_response.body, 'Solo guardar PDF'
  end

  def test_an_upload_with_a_queued_job_leaves_the_inbox
    token = classified('AMEX 2508.pdf')
    process(token, 'AMEX', '2508')

    get '/inbox'

    assert_includes last_response.body, 'Nada por confirmar'
  end

  def test_an_upload_whose_job_failed_comes_back_with_the_choice_and_the_job
    @client.classification = { 'account' => 'BBVA', 'period_start' => '2026-07-24', 'period_end' => '2026-08-23' }
    token = classified('estado.pdf')
    @client.extract_error = Frijolero::LLM::RateLimitError.new('rate limited', status: 429)
    process(token, 'AMEX', '2508')
    job = Frijolero::App.jobs.work_one

    get '/inbox'

    assert_includes last_response.body, %(<a class="status failed" href="/jobs/#{job.id}">falló</a>)
    assert_match(/value="AMEX"\s+selected/, last_response.body)
    assert_includes last_response.body, %(name="period[#{token}]" value="2508")
    refute_includes last_response.body, 'Procesar los listos'
  end

  # Procesar and the job behind it.
  def test_processing_one_upload_runs_its_job_with_the_chosen_account
    @client.classification = { 'account' => 'BBVA', 'period_start' => '2026-07-24', 'period_end' => '2026-08-23' }
    token = classified('estado.pdf')

    process(token, 'AMEX', '2508')

    assert_equal 303, last_response.status
    job = Frijolero::App.jobs.find(last_response.location[%r{/jobs/(.+)\z}, 1])
    assert_equal ['AMEX 2508', token], [job.label, job.token]
    Frijolero::App.jobs.work_one
    assert_equal 'ok', job.status
    assert File.exist?(Frijolero::Config.statement_path('AMEX', '2508', 'beancount'))
    assert_includes File.read(Frijolero::Config.main_file), 'include'
    refute Dir.exist?(File.join(@incoming, token))
  end

  # The order is the durability property: pull before anything is written, the PDF in
  # S3 before the extraction is paid for, the push only once a statement landed.
  def test_the_job_pulls_saves_the_pdf_and_pushes_in_that_order
    process(classified('AMEX 2508.pdf'), 'AMEX', '2508')

    Frijolero::App.jobs.work_one

    assert_equal %i[pull put commit_and_push], @order
    assert_equal ['AMEX 2508'], @repo.messages
    assert_equal ['frijolero/accounts/AMEX/AMEX 2508.pdf'], @s3.calls
  end

  # A clone that cannot pull is a clone that cannot push either, so there is no point
  # paying the model for the extraction.
  def test_a_failed_pull_fails_the_job_before_the_extraction
    @repo.pull_error = 'offline'
    token = classified('AMEX 2508.pdf')
    process(token, 'AMEX', '2508')

    job = Frijolero::App.jobs.work_one

    assert_equal 'failed', job.status
    assert_includes job.error, 'offline'
    assert_empty @client.extractions
    assert Dir.exist?(File.join(@incoming, token))
  end

  def test_a_failed_statement_is_never_pushed_and_keeps_the_upload
    statement('AMEX', '2508')
    token = classified('AMEX 2508.pdf')
    process(token, 'AMEX', '2508')

    job = Frijolero::App.jobs.work_one

    assert_includes job.error, 'overwrite_declined'
    refute_includes @order, :commit_and_push
    assert Dir.exist?(File.join(@incoming, token))
  end

  def test_processing_records_the_cutoff_day_from_the_printed_period_end
    @client.classification = { 'account' => 'AMEX', 'period_start' => '2026-07-04', 'period_end' => '2026-08-03' }
    token = classified('estado.pdf')

    process(token, 'AMEX', '2607')
    Frijolero::App.jobs.work_one

    assert_equal 3, Frijolero::Config.accounts['AMEX']['cutoff_day']
    assert_equal 31, Frijolero::Config.accounts['BBVA']['cutoff_day']
  end

  def test_processing_the_ready_ones_queues_a_job_each
    first = classified('AMEX 2508.pdf')
    second = classified('BBVA 2508.pdf')

    post '/inbox/process', tokens: "#{first} #{second}",
                           account: { first => 'AMEX', second => 'BBVA' }, period: { first => '2508', second => '2508' }

    assert_equal 303, last_response.status
    assert_equal '/jobs', URI(last_response.location).path
    assert_equal ['AMEX 2508', 'BBVA 2508'], Frijolero::App.jobs.all.map(&:label).sort
  end

  def test_one_bad_row_queues_nothing
    first = classified('AMEX 2508.pdf')
    second = classified('estado.pdf')

    post '/inbox/process', tokens: "#{first} #{second}",
                           account: { first => 'AMEX', second => '' }, period: { first => '2508', second => '' }

    assert_equal 422, last_response.status
    assert_empty Frijolero::App.jobs.all
  end

  def test_processing_rejects_a_bad_period_an_unknown_account_and_an_unknown_token
    token = classified('AMEX 2508.pdf')

    process(token, 'AMEX', '25-08')
    assert_equal 422, last_response.status
    process(token, 'HSBC', '2508')
    assert_equal 422, last_response.status
    process('a' * 16, 'AMEX', '2508')
    assert_equal 422, last_response.status
    assert_empty Frijolero::App.jobs.all
  end

  def test_processing_with_overwrite_replaces_the_statement
    statement('AMEX', '2508')
    token = classified('AMEX 2508.pdf')

    process(token, 'AMEX', '2508', overwrite: { token => '1' })
    job = Frijolero::App.jobs.work_one

    assert_equal 'ok', job.status
  end

  def test_processing_without_a_model_key_is_rejected_with_the_variable_name
    token = classified('AMEX 2508.pdf')
    Frijolero::App.client = nil

    without_env('OPENAI_API_KEY') { process(token, 'AMEX', '2508') }

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'OPENAI_API_KEY'
    assert_empty Frijolero::App.jobs.all
  end

  # Solo guardar PDF and Descartar.
  def test_saving_only_the_pdf_puts_it_in_s3_without_a_job
    token = classified('estado.pdf')

    post '/inbox/backup', token: token, account: { token => 'AMEX' }, period: { token => '2508' }

    assert_equal 303, last_response.status
    assert_equal '/inbox', URI(last_response.location).path
    assert_equal ['frijolero/accounts/AMEX/AMEX 2508.pdf'], @s3.calls
    assert_equal [:put], @order
    assert_empty Frijolero::App.inbox.items
    assert_empty Frijolero::App.jobs.all
  end

  def test_saving_only_the_pdf_keeps_the_upload_when_s3_fails
    token = classified('AMEX 2508.pdf')
    @s3.put_error = 'boom'

    post '/inbox/backup', token: token, account: { token => 'AMEX' }, period: { token => '2508' }

    assert_equal 502, last_response.status
    assert_includes last_response.body, 'boom'
    assert_equal [token], Frijolero::App.inbox.items.map(&:token)
  end

  def test_saving_only_the_pdf_rejects_an_unknown_account
    token = classified('AMEX 2508.pdf')

    post '/inbox/backup', token: token, account: { token => 'HSBC' }, period: { token => '2508' }

    assert_equal 422, last_response.status
    assert_empty @s3.calls
  end

  def test_discard_deletes_the_upload
    token = classified('AMEX 2508.pdf')

    post '/inbox/discard', token: token

    assert_equal 303, last_response.status
    assert_equal '/inbox', URI(last_response.location).path
    assert_empty Frijolero::App.inbox.items
    assert_empty @s3.calls
  end

  def test_discard_of_an_unknown_token_is_rejected
    post '/inbox/discard', token: '../incoming'

    assert_equal 422, last_response.status
  end

  # The job pages.
  def test_job_page_refreshes_while_running_and_links_when_done
    process(classified('AMEX 2508.pdf'), 'AMEX', '2508')
    job_id = last_response.location[%r{/jobs/(.+)\z}, 1]

    get "/jobs/#{job_id}"
    assert_includes last_response.body, 'http-equiv="refresh"'

    Frijolero::App.jobs.work_one
    get "/jobs/#{job_id}"
    refute_includes last_response.body, 'http-equiv="refresh"'
    assert_includes last_response.body, '/accounts/AMEX/2508'
  end

  def test_job_page_shows_the_error_for_a_failed_job
    statement('AMEX', '2508')
    process(classified('AMEX 2508.pdf'), 'AMEX', '2508')
    job = Frijolero::App.jobs.work_one

    get "/jobs/#{job.id}"

    assert_includes last_response.body, 'overwrite_declined'
  end

  # A 429 fails the job at extraction, before the local PDF is deleted, so the upload can run again.
  def test_a_failed_extraction_offers_a_retry_that_queues_the_same_upload
    token = classified('AMEX 2508.pdf')
    job_id = failed_job(token)

    get "/jobs/#{job_id}"
    assert_includes last_response.body, 'Reintentar'

    @client.extract_error = nil
    post "/jobs/#{job_id}/retry"
    retry_job = Frijolero::App.jobs.find(last_response.location[%r{/jobs/(.+)\z}, 1])
    Frijolero::App.jobs.work_one

    assert_equal ['AMEX 2508', token, 'ok'], [retry_job.label, retry_job.token, retry_job.status]
  end

  def test_no_retry_once_that_statement_exists
    job_id = failed_job(classified('AMEX 2508.pdf'))
    statement('AMEX', '2508')

    get "/jobs/#{job_id}"
    refute_includes last_response.body, 'Reintentar'

    post "/jobs/#{job_id}/retry"
    assert_equal 422, last_response.status
  end

  def test_no_retry_without_a_model_key
    job_id = failed_job(classified('AMEX 2508.pdf'))
    Frijolero::App.client = nil

    get "/jobs/#{job_id}"
    refute_includes last_response.body, 'Reintentar'

    without_env('OPENAI_API_KEY') { post "/jobs/#{job_id}/retry" }
    assert_equal 422, last_response.status
    assert_includes last_response.body, 'OPENAI_API_KEY'
  end

  def test_no_retry_without_the_uploaded_pdf
    token = classified('AMEX 2508.pdf')
    job_id = failed_job(token)
    FileUtils.rm_rf(File.join(@incoming, token))

    get "/jobs/#{job_id}"

    refute_includes last_response.body, 'Reintentar'
  end

  def test_job_page_404s_for_an_unknown_id
    get '/jobs/nope'

    assert_equal 404, last_response.status
  end

  def test_jobs_index_lists_the_label_and_the_status_in_spanish
    process(classified('AMEX 2508.pdf'), 'AMEX', '2508')

    get '/jobs'

    assert_includes last_response.body, 'AMEX 2508'
    assert_includes last_response.body, '<span class="status queued">en cola</span>'
  end

  def test_pdf_download_redirects_to_s3_presigned_url
    get '/accounts/AMEX/2508/pdf'

    assert_equal 302, last_response.status
    assert_equal 'https://s3.example/frijolero/accounts/AMEX/AMEX%202508.pdf?sig=1', last_response.headers['Location']
    assert_equal ['frijolero/accounts/AMEX/AMEX 2508.pdf'], Frijolero::App.s3.calls
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

    get '/accounts/BBVA%20TDC/2508/pdf'

    assert_equal 302, last_response.status
    assert_equal 'https://s3.example/frijolero/accounts/BBVA%20TDC/BBVA%20TDC%202508.pdf?sig=1',
                 last_response.headers['Location']
    assert_equal ['frijolero/accounts/BBVA TDC/BBVA TDC 2508.pdf'], Frijolero::App.s3.calls
  end

  def test_pdf_download_returns_404_for_unknown_account
    get '/accounts/UNKNOWN/2508/pdf'

    assert_equal 404, last_response.status
    assert_empty Frijolero::App.s3.calls
  end

  def test_pdf_download_returns_404_for_invalid_period
    get '/accounts/AMEX/25-08/pdf'

    assert_equal 404, last_response.status
    assert_empty Frijolero::App.s3.calls
  end

  private

  # The token of a new upload through the API, before the classifier.
  def api_upload(filename)
    before = Frijolero::App.inbox.items.map(&:token)
    post '/api/upload', pdf: pdf_upload(filename)
    (Frijolero::App.inbox.items.map(&:token) - before).first
  end

  def classified(filename)
    api_upload(filename).tap { @worker.work_one }
  end

  def process(token, account, period, **)
    post '/inbox/process', tokens: token, account: { token => account }, period: { token => period }, **
  end

  # The id of a job that failed at extraction with a rate limit.
  def failed_job(token)
    @client.extract_error = Frijolero::LLM::RateLimitError.new('rate limited', status: 429)
    process(token, 'AMEX', '2508')
    Frijolero::App.jobs.work_one.id
  end

  def statement(account, period)
    path = Frijolero::Config.statement_path(account, period, 'beancount')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, '')
  end

  def pdf_upload(filename, name: nil)
    path = File.join(@dir, "upload-#{rand(1_000_000)}-#{filename}")
    File.write(path, "%PDF-1.4\n")
    Rack::Test::UploadedFile.new(path, 'application/pdf', original_filename: name || filename)
  end

  def restore_env(key, previous_value)
    if previous_value.nil?
      ENV.delete(key)
    else
      ENV[key] = previous_value
    end
  end
end
