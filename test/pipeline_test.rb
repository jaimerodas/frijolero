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
end
