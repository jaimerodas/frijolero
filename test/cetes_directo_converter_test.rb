# frozen_string_literal: true

require "test_helper"

class CetesDirectoConverterTest < Minitest::Test
  include TestHelpers

  def test_converts_interest_payment
    with_temp_dir do |dir|
      output = convert_fixture(dir)
      content = read_output(output)

      assert_includes content, '2026-02-05 * "CETESDirecto" "Pago de intereses"'
      assert_includes content, "Assets:Investments:CETESDirecto  500.00 MXN"
      assert_includes content, "Income:Interest"
    end
  end

  def test_converts_tax_withholding
    with_temp_dir do |dir|
      output = convert_fixture(dir)
      content = read_output(output)

      assert_includes content, '2026-02-05 * "CETESDirecto" "Retención ISR BPAG28 280504"'
      assert_includes content, "Assets:Investments:CETESDirecto  -75.00 MXN"
      assert_includes content, "Expenses:Taxes:ISR"
    end
  end

  def test_converts_cash_out
    with_temp_dir do |dir|
      output = convert_fixture(dir)
      content = read_output(output)

      assert_includes content, '2026-02-10 * "CETESDirecto" "Retiro"'
      assert_includes content, "Assets:Investments:CETESDirecto  -10000.00 MXN"
      assert_includes content, "Assets:BBVA"
    end
  end

  def test_converts_cash_in
    with_temp_dir do |dir|
      output = convert_fixture(dir)
      content = read_output(output)

      assert_includes content, '2026-02-15 * "CETESDirecto" "Depósito"'
      assert_includes content, "Assets:Investments:CETESDirecto  5000.00 MXN"
      assert_includes content, "Assets:BBVA"
    end
  end

  def test_skips_fund_buy_and_sell
    with_temp_dir do |dir|
      output = convert_fixture(dir)
      content = read_output(output)

      refute_includes content, "COMPSI"
      refute_includes content, "VTASI"
      refute_includes content, "fund_buy"
      refute_includes content, "fund_sell"
    end
  end

  def test_generates_mark_to_market
    with_temp_dir do |dir|
      output = convert_fixture(dir)
      content = read_output(output)

      # Only tracked movements: interest(+500), tax(-75), cash_out(-10000), cash_in(+5000)
      # expected = 100000.50 + 5500 - 10075 = 95425.50
      # unrealized = 91200.10 - 95425.50 = -4225.40
      assert_includes content, '2026-02-28 * "CETESDirecto" "Plusvalía del periodo"'
      assert_includes content, "Assets:Investments:CETESDirecto  -4225.40 MXN"
      assert_includes content, "Income:Gains"
    end
  end

  def test_generates_balance_assertion
    with_temp_dir do |dir|
      output = convert_fixture(dir)
      content = read_output(output)

      assert_includes content, "2026-03-01 balance Assets:Investments:CETESDirecto  91200.10 MXN"
    end
  end

  def test_raises_without_input
    assert_raises ArgumentError do
      Frijolero::CetesDirectoConverter.convert(input: nil, account: "Test")
    end
  end

  def test_raises_without_account
    assert_raises ArgumentError do
      Frijolero::CetesDirectoConverter.convert(input: "test.json", account: nil)
    end
  end

  private

  def convert_fixture(dir)
    output_path = File.join(dir, "output.beancount")

    Frijolero::CetesDirectoConverter.convert(
      input: fixture_path("sample_cetes_directo.json"),
      account: "Assets:Investments:CETESDirecto",
      output: output_path,
      counterpart_account: "Assets:BBVA",
      interest_account: "Income:Interest",
      tax_account: "Expenses:Taxes:ISR",
      gains_account: "Income:Gains"
    )

    output_path
  end

  def read_output(path)
    File.read(path, encoding: "UTF-8")
  end
end
