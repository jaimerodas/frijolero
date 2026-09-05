# frozen_string_literal: true

require 'test_helper'
require 'fileutils'
require 'date'

class ClassifierTest < Minitest::Test
  include TestHelpers

  TODAY = Date.new(2026, 9, 5)

  class FakeClient
    attr_reader :uploaded, :requests

    def initialize(response)
      @response = response
      @uploaded = []
      @requests = []
    end

    def upload_file(path)
      @uploaded << path
      'file-1'
    end

    def extract_transactions(_file_id, spec)
      @requests << spec
      @response
    end
  end

  def setup_accounts(dir)
    File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
        description: "Amex Platinum card, MXN"
      BBVA:
        beancount_account: "Assets:BBVA"
    YAML
    FileUtils.mkdir_p(File.join(dir, 'config', 'prompts'))
    FileUtils.cp_r(File.expand_path('../lib/frijolero/templates/prompts/classify', __dir__),
                   File.join(dir, 'config', 'prompts', 'classify'))
  end

  def test_known_filename_answers_without_openai_call
    with_ledger_dir do |dir|
      setup_accounts(dir)
      client = FakeClient.new({})
      result = Frijolero::Classifier.new(client: client, today: TODAY).classify('AMEX 2508.pdf')

      assert_equal 'AMEX', result.account
      assert_equal '2508', result.period
      assert_nil result.file_id
      assert_empty client.uploaded
    end
  end

  def test_unknown_looking_filename_goes_to_openai
    with_ledger_dir do |dir|
      setup_accounts(dir)
      client = FakeClient.new({ 'account' => 'unknown', 'period_start' => '2026-08-01', 'period_end' => '2026-08-31' })
      Frijolero::Classifier.new(client: client, today: TODAY).classify('Foo 2508.pdf')

      refute_empty client.uploaded
    end
  end

  def test_request_spec_fills_enum_and_instructions
    with_ledger_dir do |dir|
      setup_accounts(dir)
      client = FakeClient.new({ 'account' => 'AMEX', 'period_start' => '2026-08-01', 'period_end' => '2026-08-31' })
      Frijolero::Classifier.new(client: client, today: TODAY).classify('Foo.pdf')

      spec = client.requests.first
      assert_equal %w[AMEX BBVA unknown], spec['format']['schema']['properties']['account']['enum']
      assert spec['instructions'].end_with?("- AMEX: Amex Platinum card, MXN\n- BBVA: BBVA\n")
    end
  end

  def test_period_derives_from_period_end_across_months
    with_ledger_dir do |dir|
      setup_accounts(dir)
      client = FakeClient.new({ 'account' => 'AMEX', 'period_start' => '2026-04-23', 'period_end' => '2026-05-22' })
      result = Frijolero::Classifier.new(client: client, today: TODAY).classify('Foo.pdf')

      assert_equal '2605', result.period
    end
  end

  def test_result_carries_file_id_and_period_dates
    with_ledger_dir do |dir|
      setup_accounts(dir)
      client = FakeClient.new({ 'account' => 'AMEX', 'period_start' => '2026-08-01', 'period_end' => '2026-08-31' })
      result = Frijolero::Classifier.new(client: client, today: TODAY).classify('Foo.pdf')

      assert_equal 'file-1', result.file_id
      assert_equal '2026-08-01', result.period_start
      assert_equal '2026-08-31', result.period_end
    end
  end

  def test_end_before_start_is_unknown_with_nil_period
    assert_unknown_period('account' => 'AMEX', 'period_start' => '2026-08-31', 'period_end' => '2026-08-01')
  end

  def test_end_in_the_future_is_unknown
    assert_unknown_period('account' => 'AMEX', 'period_start' => '2026-08-01', 'period_end' => '2026-09-06')
  end

  def test_end_25_months_old_is_unknown
    assert_unknown_period('account' => 'AMEX', 'period_start' => '2024-07-01', 'period_end' => '2024-08-05')
  end

  def test_end_exactly_today_is_accepted
    with_ledger_dir do |dir|
      setup_accounts(dir)
      client = FakeClient.new({ 'account' => 'AMEX', 'period_start' => '2026-08-01', 'period_end' => '2026-09-05' })
      result = Frijolero::Classifier.new(client: client, today: TODAY).classify('Foo.pdf')

      assert_equal 'AMEX', result.account
      assert_equal '2609', result.period
    end
  end

  def test_unparseable_date_is_unknown_with_nil_period
    assert_unknown_period('account' => 'AMEX', 'period_start' => 'mayo 2026', 'period_end' => '2026-08-31')
  end

  def test_account_not_in_keys_with_plausible_dates_is_unknown_but_keeps_period
    with_ledger_dir do |dir|
      setup_accounts(dir)
      client = FakeClient.new({ 'account' => 'HSBC', 'period_start' => '2026-08-01', 'period_end' => '2026-08-31' })
      result = Frijolero::Classifier.new(client: client, today: TODAY).classify('Foo.pdf')

      assert_equal 'unknown', result.account
      assert_equal '2608', result.period
    end
  end

  def test_template_prompt_is_not_mutated_across_calls
    with_ledger_dir do |dir|
      setup_accounts(dir)
      client = FakeClient.new({ 'account' => 'AMEX', 'period_start' => '2026-08-01', 'period_end' => '2026-08-31' })
      classifier = Frijolero::Classifier.new(client: client, today: TODAY)
      classifier.classify('Foo.pdf')
      classifier.classify('Foo.pdf')

      count = client.requests.last['instructions'].scan('- AMEX:').size
      assert_equal 1, count
    end
  end

  private

  def assert_unknown_period(response)
    with_ledger_dir do |dir|
      setup_accounts(dir)
      client = FakeClient.new(response)
      result = Frijolero::Classifier.new(client: client, today: TODAY).classify('Foo.pdf')

      assert_equal 'unknown', result.account
      assert_nil result.period
    end
  end
end
