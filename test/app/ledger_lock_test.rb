# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'stringio'

# Ledger.lock keeps git and the writes to one ledger one at a time. Each operation here
# waits while another thread holds the lock, and finishes once it is free.
class LedgerLockTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  # The repo, the bucket and the model append to one shared `order`.
  class FakeRepo
    def initialize(order)
      @order = order
    end

    def pull = @order << :pull
    def commit_and_push(_message) = @order << :commit_and_push
  end

  # `on_put` runs when the PDF goes to the bucket, after the job's pull.
  class FakeS3
    attr_accessor :on_put

    def initialize(order)
      @order = order
    end

    def put(_key, _path)
      @order << :put
      on_put&.call
    end
  end

  # `extracted` gets a value as the model call runs.
  class FakeClient
    attr_reader :extracted

    def initialize(order)
      @order = order
      @extracted = Queue.new
    end

    def extract(_path, _spec)
      @order << :extract
      @extracted << true
      { 'transactions' => [{ 'date' => '2025-08-03', 'description' => 'X', 'amount' => -10.0, 'currency' => 'MXN' }] }
    end
  end

  # rledger finds nothing wrong.
  class CleanReports
    def self.check = []
  end

  MAIN = "2026-01-01 open Assets:BBVA\n"

  def setup
    @dir = enter_test_ledger
    File.write(File.join(@dir, 'config', 'accounts.yaml'), "AMEX:\n  beancount_account: \"Liabilities:Amex\"\n")
    File.write(File.join(@dir, 'main.beancount'), MAIN)
    @order = []
    @s3 = FakeS3.new(@order)
    @client = FakeClient.new(@order)
    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(@dir, '..', 'jobs.jsonl'))
    Frijolero::App.inbox = Frijolero::Inbox.new(File.join(@dir, '..', 'incoming'))
    Frijolero::App.repo = FakeRepo.new(@order)
    Frijolero::App.s3 = @s3
    Frijolero::App.client = @client
    Frijolero::App.reports = CleanReports
    Frijolero::Log.sink = StringIO.new
  end

  def teardown
    leave_test_ledger
    %i[jobs inbox repo s3 client reports].each { |name| Frijolero::App.public_send(:"#{name}=", nil) }
    Frijolero::Log.sink = $stdout
  end

  def app = Frijolero::App

  # From the PDF's put on, after the pull, another thread holds the lock: the model call
  # still runs, and the statement waits to be written and committed.
  def test_a_job_calls_the_model_outside_the_lock_and_writes_under_it
    queue_job
    @s3.on_put = -> { @release = hold_lock }
    worker = Thread.new { Frijolero::App.jobs.work_one }

    assert @client.extracted.pop(timeout: 2), 'the model call waited for the lock'
    refute worker.join(0.2), 'the job wrote while another thread held the lock'
    refute_path_exists statement

    @release.call
    assert_equal 'ok', worker.value.status
    assert_equal %i[pull put extract commit_and_push], @order
    assert_path_exists statement
  ensure
    @release&.call
  end

  def test_a_job_waits_for_the_lock_to_pull
    queue_job

    job = assert_waits_for_the_lock { Frijolero::App.jobs.work_one }

    assert_equal 'ok', job.status
  end

  def test_an_edit_waits_for_the_lock
    assert_waits_for_the_lock do
      post '/edit', file: 'main.beancount', original: MAIN, content: "#{MAIN}2026-01-01 open Assets:HSBC\n"
    end

    assert_equal 204, last_response.status
    assert_equal %i[commit_and_push], @order
  end

  def test_a_rules_save_waits_for_the_lock
    assert_waits_for_the_lock { post '/accounts/AMEX/rules', content: "start_with: {}\ninclude: {}\n" }

    assert_equal 303, last_response.status
    assert_equal %i[commit_and_push], @order
  end

  def test_actualizar_waits_for_the_lock
    assert_waits_for_the_lock { post '/ledger/pull' }

    assert_equal 303, last_response.status
    assert_equal %i[pull], @order
  end

  # A pull between the include check and the rledger run could bring a file that the
  # check never saw.
  def test_a_report_and_the_check_wait_for_the_lock
    json = '{"rows": [], "diagnostics": []}'
    Frijolero::Reports.stub(:capture, ->(*) { [json, '', 0] }) do
      assert_nil(assert_waits_for_the_lock { Frijolero::Reports.first_date })
      assert_empty(assert_waits_for_the_lock { Frijolero::Reports.check })
    end
  end

  private

  def statement = Frijolero::Config.statement_path('AMEX', '2508', 'beancount')

  # The job of one upload of AMEX 2508, queued as Procesar queues it.
  def queue_job
    pdf = File.join(@dir, '..', 'upload.pdf')
    File.write(pdf, "%PDF-1.4\n")
    token = Frijolero::App.inbox.add(pdf, 'AMEX 2508.pdf').token
    post '/inbox/process', tokens: token, account: { token => 'AMEX' }, period: { token => '2508' }
    assert_equal 303, last_response.status
  end

  # Another thread takes the lock of the test ledger and keeps it until the returned
  # lambda runs.
  def hold_lock
    taken = Queue.new
    release = Queue.new
    holder = Thread.new do
      Frijolero::Ledger.lock('test') do
        taken << true
        release.pop
      end
    end
    assert taken.pop(timeout: 1), 'the lock was not free'
    lambda {
      release << true
      holder.join
    }
  end

  # Runs the block in another thread, in this ledger, while a third thread holds the
  # lock: it has not finished, nor reached the repo, 0.2 s later, and it finishes once
  # the lock is free. Returns its value.
  def assert_waits_for_the_lock(&)
    release = hold_lock
    worker = Thread.new(Frijolero::Ledger.current) { |ledger| Frijolero::Ledger.with(ledger, &) }
    refute worker.join(0.2), 'it ran while another thread held the lock'
    assert_empty @order, 'it reached the repo while another thread held the lock'
    release.call
    worker.value
  ensure
    release&.call
  end
end
