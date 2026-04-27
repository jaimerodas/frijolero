# frozen_string_literal: true

require "test_helper"

class FintualConverterTest < Minitest::Test
  include TestHelpers

  def test_converts_deposit
    with_temp_dir do |dir|
      content = read_output(convert_fixture(dir))

      assert_includes content, '2026-03-17 * "Fintual" "Nos depositaste"'
      assert_includes content, "Assets:Fintual:Cash  20000.00 MXN"
      assert_includes content, "Assets:BBVA"
    end
  end

  def test_converts_withdrawal
    with_temp_dir do |dir|
      content = read_output(convert_fixture(dir))

      assert_includes content, '2026-03-20 * "Fintual" "Retiro"'
      assert_includes content, "Assets:Fintual:Cash  -500.00 MXN"
    end
  end

  def test_converts_buy_with_cost_basis
    with_temp_dir do |dir|
      content = read_output(convert_fixture(dir))

      assert_includes content, '2026-03-18 * "Fintual" "Compra PORTMAN-E10F"'
      assert_includes content, "Assets:Fintual:PORTMAN_E10F  11681 PORTMAN_E10F {1.335438 MXN}"
      assert_includes content, "Assets:Fintual:Cash  -15599.25 MXN"
    end
  end

  def test_converts_sell_with_gains_account
    with_temp_dir do |dir|
      content = read_output(convert_fixture(dir))

      assert_includes content, '2026-03-19 * "Fintual" "Venta STERGOB-C1"'
      assert_includes content, "Assets:Fintual:STERGOB_C1  -5949 STERGOB_C1 {} @ 3.361871 MXN"
      assert_includes content, "Assets:Fintual:Cash  19999.77 MXN"
      assert_includes content, "Income:Gains:Fintual"
    end
  end

  def test_converts_dividend
    with_temp_dir do |dir|
      content = read_output(convert_fixture(dir))

      assert_includes content, '2026-03-21 * "Fintual" "Dividendo"'
      assert_includes content, "Assets:Fintual:Cash  100.00 MXN"
      assert_includes content, "Income:Fintual:Dividends"
    end
  end

  def test_converts_interest
    with_temp_dir do |dir|
      content = read_output(convert_fixture(dir))

      assert_includes content, '2026-03-22 * "Fintual" "Intereses"'
      assert_includes content, "Assets:Fintual:Cash  50.00 MXN"
      assert_includes content, "Income:Fintual:Interest"
    end
  end

  def test_emits_price_declarations_for_holdings
    with_temp_dir do |dir|
      content = read_output(convert_fixture(dir))

      assert_includes content, "2026-03-31 price PORTMAN_E10F  1.334367 MXN"
      assert_includes content, "2026-03-31 price HAYEK_E10F  1.356461 MXN"
    end
  end

  def test_skips_price_declarations_with_missing_data
    with_temp_dir do |dir|
      content = read_output(convert_fixture(dir))

      refute_includes content, "NOPRICE_FUND"
    end
  end

  def test_skips_tax_and_fee
    with_temp_dir do |dir|
      content = read_output(convert_fixture(dir))

      refute_includes content, "2026-03-23"
      refute_includes content, "ISR"
      refute_includes content, "2026-03-24"
      refute_includes content, "Comisión"
    end
  end

  def test_run_to_writes_to_io
    io = StringIO.new

    Frijolero::FintualConverter.new(
      input: fixture_path("sample_fintual.json"),
      account: "Assets:Fintual",
      counterpart_account: "Assets:BBVA",
      dividend_account: "Income:Fintual:Dividends",
      interest_account: "Income:Fintual:Interest",
      gains_account: "Income:Gains:Fintual"
    ).run_to(io)

    assert_includes io.string, '2026-03-17 * "Fintual" "Nos depositaste"'
    assert_includes io.string, "2026-03-31 price PORTMAN_E10F  1.334367 MXN"
  end

  def test_raises_without_input
    assert_raises ArgumentError do
      Frijolero::FintualConverter.convert(input: nil, account: "Test")
    end
  end

  def test_raises_without_account
    assert_raises ArgumentError do
      Frijolero::FintualConverter.convert(input: "test.json", account: nil)
    end
  end

  def test_initializer_raises_without_input
    assert_raises ArgumentError do
      Frijolero::FintualConverter.new(input: nil, account: "Test")
    end
  end

  def test_initializer_raises_without_account
    assert_raises ArgumentError do
      Frijolero::FintualConverter.new(input: "test.json", account: nil)
    end
  end

  private

  def convert_fixture(dir)
    output_path = File.join(dir, "output.beancount")

    Frijolero::FintualConverter.convert(
      input: fixture_path("sample_fintual.json"),
      account: "Assets:Fintual",
      output: output_path,
      counterpart_account: "Assets:BBVA",
      dividend_account: "Income:Fintual:Dividends",
      interest_account: "Income:Fintual:Interest",
      gains_account: "Income:Gains:Fintual"
    )

    output_path
  end

  def read_output(path)
    File.read(path, encoding: "UTF-8")
  end
end
