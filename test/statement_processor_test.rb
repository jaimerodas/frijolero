# frozen_string_literal: true

require 'test_helper'

class StatementProcessorTest < Minitest::Test
  include TestHelpers

  def setup
    @processor = Frijolero::StatementProcessor.new(dry_run: true)
    @statement = Frijolero::Statement.new('/tmp/Amex_2601.pdf', client: nil, output_dir: '/tmp/out')
  end

  def teardown
    Frijolero::UI.auto_accept = false
  end

  def test_transaction_summary_mixed
    transactions = [
      { 'amount' => -100.0 },
      { 'amount' => -50.0 },
      { 'amount' => 25.0 }
    ]
    result = Frijolero::UI.transaction_summary(transactions)
    assert_includes result, '2 debits (150.00)'
    assert_includes result, '1 credits (25.00)'
    assert result.start_with?(': ')
  end

  def test_transaction_summary_all_debits
    transactions = [
      { 'amount' => -100.0 },
      { 'amount' => -200.0 }
    ]
    result = Frijolero::UI.transaction_summary(transactions)
    assert_includes result, '2 debits (300.00)'
    refute_includes result, 'credits'
  end

  def test_transaction_summary_all_credits
    transactions = [
      { 'amount' => 50.0 },
      { 'amount' => 75.0 }
    ]
    result = Frijolero::UI.transaction_summary(transactions)
    assert_includes result, '2 credits (125.00)'
    refute_includes result, 'debits'
  end

  def test_transaction_summary_empty
    result = Frijolero::UI.transaction_summary([])
    assert_equal '', result
  end

  def test_transaction_summary_large_amounts
    transactions = [
      { 'amount' => -12_345.67 },
      { 'amount' => -890.12 }
    ]
    result = Frijolero::UI.transaction_summary(transactions)
    # Sum of debits: 12345.67 + 890.12 = 13235.79
    assert_includes result, '2 debits (13,235.79)'
  end

  def test_format_elapsed_seconds
    assert_equal '5.2s', @statement.send(:format_elapsed, 5.23)
  end

  def test_format_elapsed_minutes
    assert_equal '2m 30.0s', @statement.send(:format_elapsed, 150.0)
  end

  def test_format_elapsed_under_one_second
    assert_equal '0.3s', @statement.send(:format_elapsed, 0.34)
  end

  def test_check_overwrite_no_existing_files
    with_temp_dir do |dir|
      json_path = File.join(dir, 'Amex_2604.json')
      beancount_path = File.join(dir, 'Amex_2604.beancount')
      assert @statement.send(:check_overwrite, json_path, beancount_path)
    end
  end

  def test_check_overwrite_existing_json_user_declines
    with_temp_dir do |dir|
      json_path = File.join(dir, 'Amex_2603.json')
      beancount_path = File.join(dir, 'Amex_2603.beancount')
      File.write(json_path, JSON.pretty_generate({
                                                   'transactions' => [
                                                     { 'date' => '2026-03-01', 'description' => 'Test',
                                                       'amount' => -100.0 },
                                                     { 'date' => '2026-03-15', 'description' => 'Test 2',
                                                       'amount' => 50.0 }
                                                   ]
                                                 }))

      Frijolero::UI.stub(:puts, nil) do
        Frijolero::UI.stub(:confirm, false) do
          refute @statement.send(:check_overwrite, json_path, beancount_path)
        end
      end
    end
  end

  def test_check_overwrite_existing_json_user_confirms
    with_temp_dir do |dir|
      json_path = File.join(dir, 'Amex_2603.json')
      beancount_path = File.join(dir, 'Amex_2603.beancount')
      File.write(json_path, JSON.pretty_generate({
                                                   'transactions' => [
                                                     { 'date' => '2026-03-01', 'description' => 'Test',
                                                       'amount' => -100.0 }
                                                   ]
                                                 }))

      Frijolero::UI.stub(:puts, nil) do
        Frijolero::UI.stub(:confirm, true) do
          assert @statement.send(:check_overwrite, json_path, beancount_path)
        end
      end
    end
  end

  def test_check_overwrite_existing_beancount_only
    with_temp_dir do |dir|
      json_path = File.join(dir, 'Amex_2603.json')
      beancount_path = File.join(dir, 'Amex_2603.beancount')
      File.write(beancount_path, 'some beancount content')

      Frijolero::UI.stub(:puts, nil) do
        Frijolero::UI.stub(:confirm, false) do
          refute @statement.send(:check_overwrite, json_path, beancount_path)
        end
      end
    end
  end

  def test_check_overwrite_corrupt_json
    with_temp_dir do |dir|
      json_path = File.join(dir, 'Amex_2603.json')
      beancount_path = File.join(dir, 'Amex_2603.beancount')
      File.write(json_path, 'not valid json{{{')

      Frijolero::UI.stub(:puts, nil) do
        Frijolero::UI.stub(:confirm, false) do
          refute @statement.send(:check_overwrite, json_path, beancount_path)
        end
      end
    end
  end

  def test_show_existing_json_info_with_movements
    with_temp_dir do |dir|
      json_path = File.join(dir, 'CetesDirecto_2603.json')
      File.write(json_path, JSON.pretty_generate({
                                                   'movements' => [
                                                     { 'type' => 'cash_in', 'amount' => 1000 },
                                                     { 'type' => 'interest_payment', 'amount' => 50 }
                                                   ]
                                                 }))

      Frijolero::UI.stub(:puts, nil) do
        Frijolero::UI.stub(:short_path, json_path) do
          @statement.send(:show_existing_json_info, json_path)
        end
      end
    end
  end

  class FakeOpenAIClient
    attr_reader :upload_calls

    def initialize(error_to_raise:, raise_until: Float::INFINITY)
      @error_to_raise = error_to_raise
      @raise_until = raise_until
      @upload_calls = 0
    end

    def upload_file(_path)
      @upload_calls += 1
      raise @error_to_raise if @upload_calls <= @raise_until

      "fake-file-id-#{@upload_calls}"
    end

    def delete_file(_id)
      nil
    end
  end

  def with_run_setup(input_dir, output_dir, &block)
    Frijolero::Config.stub(:statements_input_dir, input_dir) do
      Frijolero::Config.stub(:statements_output_dir, output_dir) do
        Frijolero::Config.stub(:openai_api_key, 'test-key') do
          Frijolero::AccountConfig.stub(:parse_filename, ->(_path) { %w[Amex 2601] }) do
            Frijolero::AccountConfig.stub(:find_config, { 'beancount_account' => 'Liabilities:Amex' }) do
              Frijolero::UI.stub(:puts, nil) do
                Frijolero::UI.stub(:frame, ->(_t, **_o, &block) { block.call }) do
                  Frijolero::UI.stub(:spinner, ->(_t, &block) { block.call(FakeSpinner.new) }, &block)
                end
              end
            end
          end
        end
      end
    end
  end

  class FakeSpinner
    def update_title(_title); end
  end

  def test_run_aborts_on_insufficient_quota
    with_temp_dir do |input_dir|
      with_temp_dir do |output_dir|
        File.write(File.join(input_dir, 'Amex_2601.pdf'), '')
        File.write(File.join(input_dir, 'Amex_2602.pdf'), '')

        fake = FakeOpenAIClient.new(
          error_to_raise: Frijolero::OpenAIClient::InsufficientQuotaError.new(
            'out of credits', status: 429, code: 'insufficient_quota'
          )
        )

        Frijolero::OpenAIClient.stub(:new, fake) do
          with_run_setup(input_dir, output_dir) do
            Frijolero::StatementProcessor.new(interactive: false).run
          end
        end

        assert_equal 1, fake.upload_calls,
                     'expected batch to abort after first InsufficientQuotaError'
      end
    end
  end

  def test_run_continues_on_network_error
    with_temp_dir do |input_dir|
      with_temp_dir do |output_dir|
        File.write(File.join(input_dir, 'Amex_2601.pdf'), '')
        File.write(File.join(input_dir, 'Amex_2602.pdf'), '')

        fake = FakeOpenAIClient.new(
          error_to_raise: Frijolero::OpenAIClient::NetworkError.new('Net::OpenTimeout: timed out')
        )

        Frijolero::OpenAIClient.stub(:new, fake) do
          with_run_setup(input_dir, output_dir) do
            Frijolero::StatementProcessor.new(interactive: false).run
          end
        end

        assert_equal 2, fake.upload_calls,
                     'expected NetworkError to not abort the batch'
      end
    end
  end
end
