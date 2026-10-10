# frozen_string_literal: true

require 'test_helper'

class CetesDirectoConverterTest < Minitest::Test
  include TestHelpers

  ACCOUNT = 'Assets:Investments:CETESDirecto'

  def test_a_coupon_takes_its_tax_and_its_bond_from_the_isr_row_of_its_folio
    assert_includes convert, <<~BEANCOUNT
      2026-02-05 * "CETESDirecto" "Pago de intereses BPAG28 280504"
        #{ACCOUNT}:Cash  425.00 MXN
        Expenses:Taxes:ISR  75.00 MXN
        Income:Interest  -500.00 MXN
    BEANCOUNT
  end

  def test_a_buy_adds_a_lot_at_the_amount_paid
    assert_includes convert, <<~BEANCOUNT
      2026-02-05 * "CETESDirecto" "Compra BONDDIA PF2"
        #{ACCOUNT}:BONDDIA-PF2  185 BONDDIA-PF2 {{425.00 MXN}}
        #{ACCOUNT}:Cash  -425.00 MXN
    BEANCOUNT
  end

  def test_a_fund_sale_books_the_difference_with_cost_as_a_gain
    assert_includes convert, <<~BEANCOUNT
      2026-02-10 * "CETESDirecto" "Venta BONDDIA PF2"
        #{ACCOUNT}:BONDDIA-PF2  -4,370 BONDDIA-PF2 {} @@ 10,018.02 MXN
        #{ACCOUNT}:Cash  10,018.02 MXN
        Income:Gains:CetesDirecto
    BEANCOUNT
  end

  def test_a_maturity_books_the_difference_with_cost_as_interest
    assert_includes convert, <<~BEANCOUNT
      2026-02-26 * "CETESDirecto" "Vencimiento CETES 260226"
        #{ACCOUNT}:CETES-260226  -1,000 CETES-260226 {} @@ 10,000.00 MXN
        #{ACCOUNT}:Cash  9,988.00 MXN
        Expenses:Taxes:ISR  12.00 MXN
        Income:Interest
    BEANCOUNT
  end

  def test_a_buy_is_dated_on_settlement
    assert_includes convert, '2026-02-27 * "CETESDirecto" "Compra CETES 270225"'
  end

  def test_transfers_move_cash_against_the_counterpart
    content = convert

    assert_includes content, <<~BEANCOUNT
      2026-02-10 * "CETESDirecto" "Retiro"
        #{ACCOUNT}:Cash  -10,000.00 MXN
        Assets:BBVA
    BEANCOUNT
    assert_includes content, <<~BEANCOUNT
      2026-02-15 * "CETESDirecto" "Depósito"
        #{ACCOUNT}:Cash  5,000.00 MXN
        Assets:BBVA
    BEANCOUNT
  end

  def test_a_tax_row_with_no_movement_in_its_folio_stands_alone
    data = fixture
    data['movements'][1]['folio'] = 'SVD999'

    assert_includes convert(data), <<~BEANCOUNT
      2026-02-05 * "CETESDirecto" "Retención ISR BPAG28 280504"
        #{ACCOUNT}:Cash  -75.00 MXN
        Expenses:Taxes:ISR  75.00 MXN
    BEANCOUNT
  end

  def test_a_centavo_between_the_summary_cash_and_the_movements_becomes_a_rounding_entry
    assert_includes convert, <<~BEANCOUNT
      2026-02-28 * "CETESDirecto" "Redondeo"
        #{ACCOUNT}:Cash  0.01 MXN
        Income:Gains:CetesDirecto
    BEANCOUNT
  end

  def test_no_rounding_entry_when_both_cash_figures_agree
    data = fixture
    data['closing_state']['cash'] = 8.02

    refute_includes convert(data), 'Redondeo'
  end

  def test_opens_the_securities_that_appear_this_month
    content = convert

    assert_includes content, %(2026-02-01 open #{ACCOUNT}:CETES-270225 CETES-270225 "FIFO")
    refute_includes content, "open #{ACCOUNT}:BONDDIA-PF2"
  end

  def test_closes_the_securities_that_are_gone_after_the_period
    content = convert

    assert_includes content, "2026-03-01 close #{ACCOUNT}:CETES-260226"
    refute_includes content, "close #{ACCOUNT}:BONDDIA-PF2"
  end

  def test_prices_every_closing_holding_at_period_end
    content = convert

    assert_includes content, '2026-02-28 price BONDDIA-PF2  2.3 MXN'
    assert_includes content, '2026-02-28 price CETES-270225  9.091 MXN'
  end

  def test_asserts_the_summary_cash_and_every_holding_the_day_after
    content = convert

    assert_includes content, "2026-03-01 balance #{ACCOUNT}:Cash  8.03 MXN"
    assert_includes content, "2026-03-01 balance #{ACCOUNT}:BONDDIA-PF2  5,815 BONDDIA-PF2"
    assert_includes content, "2026-03-01 balance #{ACCOUNT}:CETES-270225  1,650 CETES-270225"
  end

  def test_unset_targets_post_to_fixme
    io = StringIO.new
    input = fixture_path('sample_cetes_directo.json')
    Frijolero::Converters::CetesDirecto.new(input: input, account: ACCOUNT).run_to(io)

    assert_includes io.string, "  Income:FIXME  -500.00 MXN\n"
    assert_includes io.string, "  Expenses:FIXME  75.00 MXN\n"
  end

  def test_initializer_raises_without_account
    assert_raises ArgumentError do
      Frijolero::Converters::CetesDirecto.new(input: 'test.json', account: nil)
    end
  end

  private

  def fixture
    JSON.parse(File.read(fixture_path('sample_cetes_directo.json')))
  end

  def convert(data = fixture)
    with_temp_dir do |dir|
      input = File.join(dir, 'in.json')
      File.write(input, JSON.generate(data))
      io = StringIO.new
      Frijolero::Converters::CetesDirecto.new(input: input, account: ACCOUNT, targets: targets).run_to(io)
      io.string
    end
  end

  def targets
    Frijolero::Converters::AccountTargets.new(
      counterpart: 'Assets:BBVA',
      interest: 'Income:Interest',
      tax: 'Expenses:Taxes:ISR',
      gains: 'Income:Gains:CetesDirecto'
    )
  end
end
