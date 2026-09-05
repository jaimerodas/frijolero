# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class StatementTest < Minitest::Test
  include TestHelpers

  # Records what the pipeline asks of OpenAI, and answers with one transaction.
  # `order` is shared with FakeB2, so a test can see which happened first.
  class FakeClient
    attr_reader :uploads, :extractions, :deletions
    attr_accessor :extract_error, :payload

    def initialize(order = [])
      @order = order
      @uploads = []
      @extractions = []
      @deletions = []
      @payload = { 'transactions' => [
        { 'date' => '2025-08-03', 'description' => 'X', 'amount' => -10.0, 'currency' => 'MXN' }
      ] }
    end

    def upload_file(path)
      @uploads << path
      'file-up'
    end

    def extract_transactions(file_id, spec)
      @order << :extract
      @extractions << [file_id, spec]
      raise @extract_error if @extract_error

      @payload
    end

    def delete_file(file_id)
      @deletions << file_id
    end
  end

  # The bucket. `put` records the key and the local path it was told to read.
  class FakeB2
    attr_reader :calls
    attr_accessor :error

    def initialize(order = [])
      @order = order
      @calls = []
    end

    def put(key, path, **)
      @order << :put
      @calls << [key, path]
      raise @error if @error
    end
  end

  def setup
    @sink = StringIO.new
    Frijolero::UI.sink = @sink
    @order = []
    @client = FakeClient.new(@order)
    @b2 = FakeB2.new(@order)
  end

  def teardown
    Frijolero::UI.sink = $stdout
  end

  # --- helpers -----------------------------------------------------------

  def with_configured_ledger
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'),
                 "AMEX:\n  beancount_account: \"Liabilities:Amex\"\n  openai_prompt_type: default\n")
      FileUtils.mkdir_p(File.join(dir, 'config', 'prompts'))
      FileUtils.cp_r(fixture_path('prompts/default'), File.join(dir, 'config', 'prompts', 'default'))
      File.write(File.join(dir, 'transactions.beancount'), '')
      yield dir
    end
  end

  def pdf_in_temp_dir(name)
    dir = Dir.mktmpdir
    path = File.join(dir, name)
    File.write(path, '')
    path
  end

  def json_path(dir) = File.join(dir, 'accounts', 'AMEX', 'AMEX 2508.json')
  def beancount_path(dir) = File.join(dir, 'accounts', 'AMEX', 'AMEX 2508.beancount')
  def main_file(dir) = File.read(File.join(dir, 'transactions.beancount'))

  # --- tests -------------------------------------------------------------

  def test_processes_a_statement_named_after_its_account_and_period
    with_configured_ledger do |dir|
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      assert_equal Frijolero::Statement::OK, Frijolero::Statement.new(pdf, client: @client).process
      assert_path_exists json_path(dir)
      assert_path_exists beancount_path(dir)
      assert_includes main_file(dir), 'include "accounts/AMEX/AMEX 2508.beancount"'
      assert_path_exists pdf
    end
  end

  def test_deletes_the_uploaded_file_when_it_uploaded_it
    with_configured_ledger do
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')
      Frijolero::Statement.new(pdf, client: @client).process

      assert_equal ['file-up'], @client.deletions
    end
  end

  def test_account_and_period_arguments_win_over_the_filename
    with_configured_ledger do |dir|
      pdf = pdf_in_temp_dir('upload-abc123.pdf')
      statement = Frijolero::Statement.new(pdf, client: @client, account: 'AMEX', period: '2508')

      assert_equal Frijolero::Statement::OK, statement.process
      assert_path_exists json_path(dir)
      assert_path_exists beancount_path(dir)
    end
  end

  def test_given_file_id_skips_the_upload_and_is_deleted_at_the_end
    with_configured_ledger do
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')
      Frijolero::Statement.new(pdf, client: @client, file_id: 'file-given').process

      assert_empty @client.uploads
      assert_equal 'file-given', @client.extractions.first.first
      assert_equal ['file-given'], @client.deletions
    end
  end

  def test_existing_output_is_left_alone_without_overwrite
    with_configured_ledger do |dir|
      FileUtils.mkdir_p(File.dirname(beancount_path(dir)))
      File.write(beancount_path(dir), 'sentinel')
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      status = Frijolero::Statement.new(pdf, client: @client).process

      assert_equal Frijolero::Statement::OVERWRITE_DECLINED, status
      assert_equal 'sentinel', File.read(beancount_path(dir))
      assert_empty @client.extractions
      assert_includes @sink.string, 'AMEX 2508.beancount'
    end
  end

  def test_overwrite_replaces_existing_output
    with_configured_ledger do |dir|
      FileUtils.mkdir_p(File.dirname(beancount_path(dir)))
      File.write(beancount_path(dir), 'sentinel')
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      status = Frijolero::Statement.new(pdf, client: @client, overwrite: true).process

      assert_equal Frijolero::Statement::OK, status
      refute_equal 'sentinel', File.read(beancount_path(dir))
    end
  end

  def test_unknown_account_stops_before_the_client
    with_configured_ledger do
      pdf = pdf_in_temp_dir('NOPE 2508.pdf')
      status = Frijolero::Statement.new(pdf, client: @client).process

      assert_equal Frijolero::Statement::NO_ACCOUNT_CONFIG, status
      assert_empty @client.extractions
    end
  end

  def test_unparseable_filename_without_account_and_period
    with_configured_ledger do
      pdf = pdf_in_temp_dir('upload-abc123.pdf')

      assert_equal Frijolero::Statement::UNPARSEABLE, Frijolero::Statement.new(pdf, client: @client).process
    end
  end

  def test_extraction_error_reports_and_still_deletes_the_file
    with_configured_ledger do
      @client.extract_error = Frijolero::OpenAIClient::APIError.new('boom')
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      assert_equal Frijolero::Statement::ERROR, Frijolero::Statement.new(pdf, client: @client).process
      assert_equal ['file-up'], @client.deletions
    end
  end

  def test_reprocessing_does_not_duplicate_the_include_line
    with_configured_ledger do |dir|
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')
      2.times { Frijolero::Statement.new(pdf, client: @client, overwrite: true).process }

      assert_equal 1, main_file(dir).scan('include "accounts/AMEX/AMEX 2508.beancount"').size
    end
  end

  # The whole point of the order: if the extraction fails or reads badly, the PDF is
  # already in the bucket and the month can be retried without the original file.
  def test_b2_gets_the_pdf_before_the_extraction_and_the_local_copy_goes
    with_configured_ledger do
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      status = Frijolero::Statement.new(pdf, client: @client, b2: @b2).process

      assert_equal Frijolero::Statement::OK, status
      assert_equal %i[put extract], @order
      assert_equal [['frijolero/accounts/AMEX/AMEX 2508.pdf', pdf]], @b2.calls
      refute_path_exists pdf
    end
  end

  # The CLI passes no b2:, and it must not delete the user's own file.
  def test_without_b2_nothing_is_uploaded_and_the_pdf_stays
    with_configured_ledger do
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      assert_equal Frijolero::Statement::OK, Frijolero::Statement.new(pdf, client: @client).process
      assert_path_exists pdf
      assert_empty @b2.calls
    end
  end

  # An extraction missing an amount would convert into a ledger that quietly lost
  # money. It fails the job, and the PDF stays for a retry.
  def test_an_invalid_extraction_fails_before_writing_and_keeps_the_pdf
    with_configured_ledger do |dir|
      @client.payload = { 'transactions' => [{ 'date' => 'x' }] }
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      status = Frijolero::Statement.new(pdf, client: @client, b2: @b2).process

      assert_equal Frijolero::Statement::ERROR, status
      assert_path_exists pdf
      refute_path_exists json_path(dir)
      assert_equal ['file-up'], @client.deletions
      assert_includes @sink.string, 'transactions[0] lacks description'
    end
  end

  def test_a_failed_b2_upload_stops_before_the_extraction
    with_configured_ledger do
      @b2.error = Frijolero::B2::Error.new('boom', status: 500)
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      status = Frijolero::Statement.new(pdf, client: @client, b2: @b2).process

      assert_equal Frijolero::Statement::ERROR, status
      assert_empty @client.extractions
      assert_path_exists pdf
      assert_equal ['file-up'], @client.deletions
    end
  end

  def test_dry_run_writes_nothing_and_calls_no_client
    with_configured_ledger do |dir|
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      assert_equal Frijolero::Statement::DRY_RUN, Frijolero::Statement.new(pdf, client: @client, dry_run: true).process
      refute_path_exists json_path(dir)
      refute_path_exists beancount_path(dir)
      assert_empty @client.uploads
      assert_empty @client.extractions
    end
  end
end
