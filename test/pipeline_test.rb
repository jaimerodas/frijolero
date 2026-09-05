# frozen_string_literal: true

require 'test_helper'

class PipelineTest < Minitest::Test
  include TestHelpers

  def test_for_returns_default_when_converter_type_missing
    pipeline = Frijolero::Pipeline.for('beancount_account' => 'Liabilities:Amex')
    assert_instance_of Frijolero::Pipeline::Default, pipeline
  end

  def test_for_returns_default_when_converter_type_nil
    pipeline = Frijolero::Pipeline.for('converter_type' => nil)
    assert_instance_of Frijolero::Pipeline::Default, pipeline
  end

  def test_for_handles_nil_account_config
    pipeline = Frijolero::Pipeline.for(nil)
    assert_instance_of Frijolero::Pipeline::Default, pipeline
  end

  def test_for_returns_cetes_directo_strategy
    pipeline = Frijolero::Pipeline.for('converter_type' => 'cetes_directo')
    assert_instance_of Frijolero::Pipeline::CetesDirecto, pipeline
  end

  def test_for_returns_fintual_strategy
    pipeline = Frijolero::Pipeline.for('converter_type' => 'fintual')
    assert_instance_of Frijolero::Pipeline::Fintual, pipeline
  end

  def test_for_returns_plata_strategy
    pipeline = Frijolero::Pipeline.for('converter_type' => 'plata')
    assert_instance_of Frijolero::Pipeline::Plata, pipeline
  end

  def test_for_falls_back_to_default_for_unknown_type
    pipeline = Frijolero::Pipeline.for('converter_type' => 'unknown_bank')
    assert_instance_of Frijolero::Pipeline::Default, pipeline
  end

  def test_default_runs_detailer
    pipeline = Frijolero::Pipeline::Default.new({})
    assert pipeline.runs_detailer?
  end

  def test_cetes_directo_skips_detailer
    pipeline = Frijolero::Pipeline::CetesDirecto.new({})
    refute pipeline.runs_detailer?
  end

  def test_fintual_skips_detailer
    pipeline = Frijolero::Pipeline::Fintual.new({})
    refute pipeline.runs_detailer?
  end

  def test_default_summary_counts_transactions
    pipeline = Frijolero::Pipeline::Default.new({})
    data = { 'transactions' => [{ 'amount' => -10 }, { 'amount' => 5 }] }
    assert_includes pipeline.summary(data), 'Found 2 transactions'
  end

  def test_default_summary_handles_empty
    pipeline = Frijolero::Pipeline::Default.new({})
    assert_includes pipeline.summary({}), 'Found 0 transactions'
  end

  def test_cetes_directo_summary_counts_movements
    pipeline = Frijolero::Pipeline::CetesDirecto.new({})
    data = { 'movements' => [{ 'type' => 'cash_in' }, { 'type' => 'interest_payment' }] }
    assert_equal 'Found 2 movements', pipeline.summary(data)
  end

  def test_fintual_summary_counts_transactions
    pipeline = Frijolero::Pipeline::Fintual.new({})
    data = { 'transactions' => [{}, {}, {}] }
    assert_equal 'Found 3 transactions', pipeline.summary(data)
  end

  def test_plata_skips_detailer
    pipeline = Frijolero::Pipeline::Plata.new({})
    refute pipeline.runs_detailer?
  end

  # An Alpaca statement spreads its movements over four tables; counting only
  # "transactions" would report 1 for a month of a dozen dividends.
  def test_plata_summary_counts_every_table
    pipeline = Frijolero::Pipeline::Plata.new({})
    data = {
      'transactions' => [plata_row('Trade Entry')],
      'income' => [plata_row('Dividends'), plata_row('Dividends')],
      'fees' => [{ 'trade_date' => '2025-11-01', 'net_amount' => '-1.00' }],
      'deposits_withdrawals' => [plata_row('Journal Entry(Cash)')]
    }
    assert_equal 'Found 5 movements', pipeline.summary(data)
  end

  # Sweep rows never reach the ledger, so counting them among the movements would
  # make the summary disagree with the file the converter writes.
  def test_plata_summary_reports_ignored_sweeps_separately
    pipeline = Frijolero::Pipeline::Plata.new({})
    data = {
      'transactions' => [plata_row('Trade Entry'), plata_row('High-Yield Cash Sweep')]
    }
    assert_equal 'Found 1 movement, 1 cash sweep ignored', pipeline.summary(data)
  end

  def test_plata_summary_handles_an_empty_statement
    pipeline = Frijolero::Pipeline::Plata.new({})
    assert_equal 'Found 0 movements', pipeline.summary({})
  end

  def test_plata_convert_passes_all_account_config_keys
    captured = nil
    Frijolero::Converters::Plata.stub(:convert, ->(**kwargs) { captured = kwargs }) do
      pipeline = Frijolero::Pipeline::Plata.new(
        'beancount_account' => 'Assets:Investments:Plata',
        'counterpart_account' => 'Assets:Bank',
        'dividend_account' => 'Income:Dividends:Plata',
        'interest_account' => 'Income:Interest',
        'gains_account' => 'Income:Gains:Plata',
        'fees_account' => 'Expenses:Fees:Plata',
        'withholding_account' => 'Expenses:Taxes:Withholding:USA'
      )
      pipeline.convert(json_path: '/in.json', output: '/out.beancount')
    end
    assert_equal 'Assets:Investments:Plata', captured[:account]
    assert_equal 'Assets:Bank', captured[:targets].counterpart
    assert_equal 'Income:Dividends:Plata', captured[:targets].dividend
    assert_equal 'Income:Gains:Plata', captured[:targets].gains
    assert_equal 'Expenses:Fees:Plata', captured[:targets].fees
    assert_equal 'Expenses:Taxes:Withholding:USA', captured[:targets].withholding
  end

  def test_beancount_account_pulled_from_config
    pipeline = Frijolero::Pipeline::Default.new('beancount_account' => 'Liabilities:Amex')
    assert_equal 'Liabilities:Amex', pipeline.beancount_account
  end

  def test_default_convert_delegates_to_beancount_converter
    captured = nil
    Frijolero::Converters::Beancount.stub(:convert, ->(**kwargs) { captured = kwargs }) do
      pipeline = Frijolero::Pipeline::Default.new('beancount_account' => 'Liabilities:Amex')
      pipeline.convert(json_path: '/in.json', output: '/out.beancount')
    end
    assert_equal '/in.json', captured[:input]
    assert_equal 'Liabilities:Amex', captured[:account]
    assert_equal '/out.beancount', captured[:output]
  end

  def test_cetes_directo_convert_passes_all_account_config_keys
    captured = nil
    Frijolero::Converters::CetesDirecto.stub(:convert, ->(**kwargs) { captured = kwargs }) do
      pipeline = Frijolero::Pipeline::CetesDirecto.new(
        'beancount_account' => 'Assets:Cetes',
        'counterpart_account' => 'Assets:Bank',
        'interest_account' => 'Income:Interest',
        'tax_account' => 'Expenses:Tax',
        'gains_account' => 'Income:Gains'
      )
      pipeline.convert(json_path: '/in.json', output: '/out.beancount')
    end
    assert_equal 'Assets:Cetes', captured[:account]
    assert_equal 'Assets:Bank', captured[:targets].counterpart
    assert_equal 'Income:Interest', captured[:targets].interest
    assert_equal 'Expenses:Tax', captured[:targets].tax
    assert_equal 'Income:Gains', captured[:targets].gains
  end

  def test_cetes_directo_convert_uses_default_gains_account
    captured = nil
    Frijolero::Converters::CetesDirecto.stub(:convert, ->(**kwargs) { captured = kwargs }) do
      pipeline = Frijolero::Pipeline::CetesDirecto.new('beancount_account' => 'Assets:Cetes')
      pipeline.convert(json_path: '/in.json', output: '/out.beancount')
    end
    assert_equal Frijolero::Converters::AccountTargets::DEFAULT_GAINS, captured[:targets].gains
  end

  def test_fintual_convert_passes_all_account_config_keys
    captured = nil
    Frijolero::Converters::Fintual.stub(:convert, ->(**kwargs) { captured = kwargs }) do
      pipeline = Frijolero::Pipeline::Fintual.new(
        'beancount_account' => 'Assets:Fintual',
        'counterpart_account' => 'Assets:Bank',
        'dividend_account' => 'Income:Dividend',
        'interest_account' => 'Income:Interest',
        'gains_account' => 'Income:Gains'
      )
      pipeline.convert(json_path: '/in.json', output: '/out.beancount')
    end
    assert_equal 'Assets:Fintual', captured[:account]
    assert_equal 'Assets:Bank', captured[:targets].counterpart
    assert_equal 'Income:Dividend', captured[:targets].dividend
    assert_equal 'Income:Interest', captured[:targets].interest
    assert_equal 'Income:Gains', captured[:targets].gains
  end

  def test_fintual_convert_uses_default_gains_account
    captured = nil
    Frijolero::Converters::Fintual.stub(:convert, ->(**kwargs) { captured = kwargs }) do
      pipeline = Frijolero::Pipeline::Fintual.new('beancount_account' => 'Assets:Fintual')
      pipeline.convert(json_path: '/in.json', output: '/out.beancount')
    end
    assert_equal Frijolero::Converters::AccountTargets::DEFAULT_GAINS, captured[:targets].gains
  end

  def test_default_convert_accepts_account_override
    captured = nil
    Frijolero::Converters::Beancount.stub(:convert, ->(**kwargs) { captured = kwargs }) do
      pipeline = Frijolero::Pipeline::Default.new('beancount_account' => 'Liabilities:Amex')
      pipeline.convert(json_path: '/in.json', output: '/out.beancount', account: 'Override:Account')
    end
    assert_equal 'Override:Account', captured[:account]
  end

  def test_default_convert_passes_expense_account_when_set
    captured = nil
    Frijolero::Converters::Beancount.stub(:convert, ->(**kwargs) { captured = kwargs }) do
      pipeline = Frijolero::Pipeline::Default.new('beancount_account' => 'Liabilities:Amex')
      pipeline.convert(json_path: '/in.json', output: '/out.beancount', expense_account: 'Expenses:Custom')
    end
    assert_equal 'Expenses:Custom', captured[:expense_account]
  end

  def test_default_convert_omits_expense_account_when_nil
    captured = nil
    Frijolero::Converters::Beancount.stub(:convert, ->(**kwargs) { captured = kwargs }) do
      pipeline = Frijolero::Pipeline::Default.new('beancount_account' => 'Liabilities:Amex')
      pipeline.convert(json_path: '/in.json', output: '/out.beancount')
    end
    refute captured.key?(:expense_account)
  end

  def test_cetes_directo_convert_accepts_account_override
    captured = nil
    Frijolero::Converters::CetesDirecto.stub(:convert, ->(**kwargs) { captured = kwargs }) do
      pipeline = Frijolero::Pipeline::CetesDirecto.new('beancount_account' => 'Assets:Cetes')
      pipeline.convert(json_path: '/in.json', output: '/out.beancount', account: 'Override:Cetes')
    end
    assert_equal 'Override:Cetes', captured[:account]
  end

  def test_strategies_ignore_unknown_kwargs
    Frijolero::Converters::CetesDirecto.stub(:convert, ->(**) {}) do
      pipeline = Frijolero::Pipeline::CetesDirecto.new('beancount_account' => 'Assets:Cetes')
      # expense_account is meaningless for CetesDirecto, must not raise
      pipeline.convert(json_path: '/in.json', output: '/out.beancount', expense_account: 'ignored')
    end
  end

  # --- validate! ---------------------------------------------------------

  def test_validate_rejects_a_payload_that_is_not_an_object
    error = assert_raises(Frijolero::Pipeline::InvalidData) do
      Frijolero::Pipeline::Default.new({}).validate!([{ 'date' => '2025-08-03' }])
    end
    assert_match(/not a JSON object/, error.message)
  end

  def test_default_validate_accepts_a_complete_transaction
    assert_valid Frijolero::Pipeline::Default.new({}),
                 'transactions' => [{ 'date' => '2025-08-03', 'description' => 'X', 'amount' => -10 }]
  end

  def test_default_validate_names_the_row_and_the_missing_key
    error = assert_raises(Frijolero::Pipeline::InvalidData) do
      Frijolero::Pipeline::Default.new({}).validate!(
        'transactions' => [{ 'date' => '2025-08-03', 'description' => 'X', 'amount' => -10 },
                           { 'date' => '2025-08-04', 'description' => 'Y' }]
      )
    end
    assert_equal 'transactions[1] lacks amount', error.message
  end

  def test_cetes_directo_validate_accepts_a_movement
    assert_valid Frijolero::Pipeline::CetesDirecto.new({}),
                 'movements' => [{ 'movement_type' => 'cash_in', 'settlement_date' => '2025-08-03',
                                   'cash_inflow' => '100' }]
  end

  # Either date will do: the converter prefers settlement_date and falls back.
  def test_cetes_directo_validate_accepts_a_movement_with_only_a_trade_date
    assert_valid Frijolero::Pipeline::CetesDirecto.new({}),
                 'movements' => [{ 'movement_type' => 'cash_out', 'trade_date' => '2025-08-03' }]
  end

  def test_cetes_directo_validate_requires_a_date
    error = assert_raises(Frijolero::Pipeline::InvalidData) do
      Frijolero::Pipeline::CetesDirecto.new({}).validate!('movements' => [{ 'movement_type' => 'cash_in' }])
    end
    assert_equal 'movements[0] lacks settlement_date or trade_date', error.message
  end

  def test_fintual_validate_accepts_a_transaction
    assert_valid Frijolero::Pipeline::Fintual.new({}),
                 'transactions' => [{ 'trade_date' => '2025-08-03', 'transaction_type' => 'buy',
                                      'reported_amount' => '100' }]
  end

  # Fintual's money column is reported_amount, so a row with the default converter's
  # `amount` is not a valid Fintual row.
  def test_fintual_validate_requires_reported_amount
    error = assert_raises(Frijolero::Pipeline::InvalidData) do
      Frijolero::Pipeline::Fintual.new({}).validate!(
        'transactions' => [{ 'trade_date' => '2025-08-03', 'transaction_type' => 'buy', 'amount' => '100' }]
      )
    end
    assert_equal 'transactions[0] lacks reported_amount', error.message
  end

  def test_plata_validate_accepts_the_four_tables_and_the_holdings
    assert_valid Frijolero::Pipeline::Plata.new({}),
                 'transactions' => [plata_row('Trade Entry')], 'income' => [], 'fees' => [],
                 'deposits_withdrawals' => [], 'holdings' => []
  end

  def test_plata_validate_requires_every_table
    error = assert_raises(Frijolero::Pipeline::InvalidData) do
      Frijolero::Pipeline::Plata.new({}).validate!(
        'transactions' => [], 'income' => [], 'fees' => [], 'deposits_withdrawals' => []
      )
    end
    assert_equal 'holdings is not an array', error.message
  end

  private

  # Minitest has no assert_nothing_raised, and the valid cases need an assertion.
  def assert_valid(pipeline, data)
    pipeline.validate!(data)
    pass "#{pipeline.class} accepted the payload"
  end

  def plata_row(entry_type)
    { 'trade_date' => '2025-11-01', 'entry_type' => entry_type, 'net_amount' => '1.00' }
  end
end
