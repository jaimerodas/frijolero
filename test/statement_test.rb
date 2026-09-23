# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class StatementTest < Minitest::Test
  include TestHelpers

  # Records what the pipeline asks of the model, and answers with one transaction.
  # `order` is shared with FakeS3, so a test can see which happened first.
  class FakeClient
    attr_reader :extractions
    attr_accessor :extract_error, :payload

    def initialize(order = [])
      @order = order
      @extractions = []
      @payload = { 'transactions' => [
        { 'date' => '2025-08-03', 'description' => 'X', 'amount' => -10.0, 'currency' => 'MXN' }
      ] }
    end

    def extract(path, spec)
      @order << :extract
      @extractions << [path, spec]
      raise @extract_error if @extract_error

      @payload
    end
  end

  # The bucket. `put` records the key and the local path it was told to read.
  class FakeS3
    attr_reader :calls
    attr_accessor :error

    def initialize(order = [])
      @order = order
      @calls = []
    end

    def put(key, path)
      @order << :put
      @calls << [key, path]
      raise @error if @error
    end
  end

  def setup
    @sink = StringIO.new
    Frijolero::Log.sink = @sink
    @order = []
    @client = FakeClient.new(@order)
    @s3 = FakeS3.new(@order)
  end

  def teardown
    Frijolero::Log.sink = $stdout
  end

  # --- helpers -----------------------------------------------------------

  def with_configured_ledger
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'),
                 "AMEX:\n  beancount_account: \"Liabilities:Amex\"\n  openai_prompt_type: default\n")
      FileUtils.mkdir_p(File.join(dir, 'config', 'prompts'))
      FileUtils.cp_r(fixture_path('prompts/default'), File.join(dir, 'config', 'prompts', 'default'))
      File.write(File.join(dir, 'main.beancount'), '')
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
  def main_file(dir) = File.read(File.join(dir, 'main.beancount'))

  def statement(pdf, account: 'AMEX', period: '2508', **)
    Frijolero::Statement.new(pdf, client: @client, s3: @s3, account: account, period: period, **)
  end

  # --- tests -------------------------------------------------------------

  def test_processes_a_statement_into_the_account_and_period_it_is_given
    with_configured_ledger do |dir|
      pdf = pdf_in_temp_dir('upload-abc123.pdf')

      assert_equal Frijolero::Statement::OK, statement(pdf).process
      assert_path_exists json_path(dir)
      assert_path_exists beancount_path(dir)
      assert_includes main_file(dir), 'include "accounts/AMEX/AMEX 2508.beancount"'
    end
  end

  def test_existing_output_is_left_alone_without_overwrite
    with_configured_ledger do |dir|
      FileUtils.mkdir_p(File.dirname(beancount_path(dir)))
      File.write(beancount_path(dir), 'sentinel')
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      status = statement(pdf).process

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

      status = statement(pdf, overwrite: true).process

      assert_equal Frijolero::Statement::OK, status
      refute_equal 'sentinel', File.read(beancount_path(dir))
    end
  end

  def test_unknown_account_stops_before_the_client
    with_configured_ledger do
      pdf = pdf_in_temp_dir('NOPE 2508.pdf')
      status = statement(pdf, account: 'NOPE').process

      assert_equal Frijolero::Statement::NO_ACCOUNT_CONFIG, status
      assert_empty @client.extractions
    end
  end

  def test_extraction_error_is_reported_and_ends_the_statement
    with_configured_ledger do
      @client.extract_error = Frijolero::LLM::APIError.new('boom', status: 500)
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      assert_equal Frijolero::Statement::ERROR, statement(pdf).process
      assert_includes @sink.string, 'OpenAI returned an error (HTTP 500): boom'
    end
  end

  def test_reprocessing_does_not_duplicate_the_include_line
    with_configured_ledger do |dir|
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')
      2.times { statement(pdf, overwrite: true).process }

      assert_equal 1, main_file(dir).scan('include "accounts/AMEX/AMEX 2508.beancount"').size
    end
  end

  # The whole point of the order: if the extraction fails or reads badly, the PDF is
  # already in the bucket and the month can be retried without the original file.
  def test_s3_gets_the_pdf_before_the_extraction_and_the_local_copy_goes
    with_configured_ledger do
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      status = statement(pdf).process

      assert_equal Frijolero::Statement::OK, status
      assert_equal %i[put extract], @order
      assert_equal [['frijolero/accounts/AMEX/AMEX 2508.pdf', pdf]], @s3.calls
      assert_equal pdf, @client.extractions.first.first
      refute_path_exists pdf
    end
  end

  # An extraction missing an amount would convert into a ledger that quietly lost
  # money. It fails the job, and the PDF stays for a retry.
  def test_an_invalid_extraction_fails_before_writing_and_keeps_the_pdf
    with_configured_ledger do |dir|
      @client.payload = { 'transactions' => [{ 'date' => 'x' }] }
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      status = statement(pdf).process

      assert_equal Frijolero::Statement::ERROR, status
      assert_path_exists pdf
      refute_path_exists json_path(dir)
      assert_includes @sink.string, 'transactions[0] lacks description'
    end
  end

  def test_a_failed_s3_upload_stops_before_the_extraction
    with_configured_ledger do
      @s3.error = Frijolero::S3::Error.new('boom', status: 500)
      pdf = pdf_in_temp_dir('AMEX 2508.pdf')

      status = statement(pdf).process

      assert_equal Frijolero::Statement::ERROR, status
      assert_empty @client.extractions
      assert_path_exists pdf
    end
  end

  # --- multi ------------------------------------------------------------

  # The pipeline shapes the request: a multi account gets its labels as an enum.
  def test_multi_account_fills_the_enum_and_posts_from_each_section
    with_configured_ledger do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
        Plata Banco:
          beancount_account: "Assets:Plata:Cuenta"
          openai_prompt_type: multi
          converter_type: multi
          accounts:
            Plata Cuenta: "Assets:Plata:Cuenta"
            Ahorro Flexible: "Assets:Plata:Ahorro"
      YAML
      FileUtils.cp_r(File.expand_path('../templates/prompts/multi', __dir__),
                     File.join(dir, 'config', 'prompts', 'multi'))
      @client.payload = { 'transactions' => [
        { 'date' => '2026-09-10', 'description' => 'Rendimientos', 'amount' => 1733.28, 'account' => 'Ahorro Flexible' }
      ] }
      pdf = pdf_in_temp_dir('Plata Banco 2608.pdf')

      assert_equal Frijolero::Statement::OK, statement(pdf, account: 'Plata Banco', period: '2608').process

      spec = @client.extractions.first.last
      assert_equal ['Plata Cuenta', 'Ahorro Flexible'],
                   spec.dig('format', 'schema', 'properties', 'transactions', 'items', 'properties', 'account', 'enum')
      beancount = File.read(File.join(dir, 'accounts', 'Plata Banco', 'Plata Banco 2608.beancount'))
      assert_includes beancount, 'Assets:Plata:Ahorro  1,733.28 MXN'
    end
  end
end
