# frozen_string_literal: true

require 'test_helper'

class PlataConverterTest < Minitest::Test
  include TestHelpers

  def test_converts_deposit
    content = convert

    assert_includes content, '2025-11-10 * "Plata" "Depósito"'
    assert_includes content, 'Assets:Investments:Plata:Cash  1000.00 USD'
    assert_includes content, 'Assets:BBVA'
  end

  def test_converts_withdrawal
    content = convert

    assert_includes content, '2025-11-11 * "Plata" "Retiro"'
    assert_includes content, 'Assets:Investments:Plata:Cash  -250.00 USD'
  end

  # The statement's own Importe is authoritative: 10 x 79.59 = 795.90, but the
  # statement reports 795.91. Total-cost syntax keeps the ledger balanced.
  def test_buy_uses_total_cost_not_rounded_unit_price
    content = convert

    assert_includes content, '2025-11-25 * "Plata" "Compra VGK"'
    assert_includes content, 'Assets:Investments:Plata:VGK  10 VGK {{795.91 USD}}'
    refute_includes content, '{79.59 USD}'
  end

  def test_buy_expenses_commission_and_debits_cash_including_it
    content = convert

    assert_includes content, 'Expenses:Fees:Plata  1.43 USD'
    assert_includes content, 'Assets:Investments:Plata:Cash  -797.34 USD'
  end

  def test_sell_credits_cash_net_of_commission_and_books_gains
    content = convert

    assert_includes content, '2025-11-25 * "Plata" "Venta NFLX"'
    assert_includes content, 'Assets:Investments:Plata:NFLX  -20 NFLX {} @@ 2133.25 USD'
    assert_includes content, 'Expenses:Fees:Plata  3.83 USD'
    assert_includes content, 'Assets:Investments:Plata:Cash  2129.42 USD'
    assert_includes content, 'Income:Gains:Plata'
  end

  def test_dividend_credits_net_amount_and_posts_withholding
    content = convert

    assert_includes content, '2025-11-05 * "Plata" "Dividendo BND"'
    assert_includes content, 'Assets:Investments:Plata:Cash  3.51 USD'
    assert_includes content, 'Expenses:Taxes:Withholding:USA  0.39 USD'
    assert_includes content, 'Income:Dividends:Plata'
  end

  def test_dividend_without_withholding_omits_the_tax_posting
    dividend = transaction_block(convert, '2025-11-06 * "Plata" "Dividendo ASML"')

    assert_includes dividend, 'Assets:Investments:Plata:Cash  4.75 USD'
    refute_includes dividend, 'Withholding'
  end

  def test_converts_interest
    content = convert

    assert_includes content, '2025-11-28 * "Plata" "Intereses"'
    assert_includes content, 'Assets:Investments:Plata:Cash  2.10 USD'
    assert_includes content, 'Income:Interest'
  end

  # NFLX: 5 previous - 20 sold = -15 expected, but the statement reports 30.
  # A 10:1 split happened with no movement row. Dated period start so the
  # sale that follows still has units to draw from.
  def test_emits_fixme_for_unreported_unit_change
    content = convert

    assert_includes content, '2025-11-01 ! "Plata" "FIXME ajuste de títulos no reportado NFLX"'
    assert_includes content, 'Assets:Investments:Plata:NFLX  45 NFLX {{0.00 USD}}'
    assert_includes content, 'Equity:FIXME'
    assert_includes content, '; esperado -15 NFLX, reportado 30 NFLX'
  end

  def test_no_fixme_when_units_reconcile
    content = convert

    # VGK: 5 previous + 10 bought = 15 reported. AAPL: unchanged at 14.
    refute_includes content, 'FIXME ajuste de títulos no reportado VGK'
    refute_includes content, 'FIXME ajuste de títulos no reportado AAPL'
  end

  # A negative delta is a REDUCTION. Asking for a lot at 0.00 finds nothing and
  # beancount rejects the whole file, so the cost stays open for the booking method.
  def test_reverse_split_leaves_cost_open_instead_of_requesting_a_zero_lot
    block = transaction_block(convert,
                              '2025-11-01 ! "Plata" "FIXME ajuste de títulos no reportado RVRS"')

    assert_includes block, 'Assets:Investments:Plata:RVRS  -12 RVRS {}'
    refute_includes block, '{{0.00 USD}}'
  end

  def test_reverse_split_hint_distinguishes_it_from_a_forward_split
    assert_includes convert, '; esperado 20 RVRS, reportado 8 RVRS (¿split inverso?)'
  end

  def test_shares_against_a_zero_opening_position_are_hinted_as_a_grant
    converter = build_converter(fixture_with('holdings' => [{
                                               'ticker' => 'MBGL', 'units_current' => '5',
                                               'units_previous' => '0', 'market_price_current' => nil
                                             }]))
    io = StringIO.new
    converter.run_to(io)

    assert_includes io.string, '(¿acciones recibidas?)'
  end

  def test_converts_fee
    content = convert

    assert_includes content, '2025-11-29 * "Plata" "Comisión administrativa"'
    assert_includes content, 'Assets:Investments:Plata:Cash  -5.00 USD'
    assert_includes content, 'Expenses:Fees:Plata'
  end

  def test_converts_tax
    content = convert

    assert_includes content, '2025-11-29 * "Plata" "ISR retenido"'
    assert_includes content, 'Assets:Investments:Plata:Cash  -1.25 USD'
    assert_includes content, 'Expenses:Taxes:ISR'
  end

  # "other" is the extractor's could-not-classify bucket. Dropping it would take
  # its cash movement with it and surface only as a failed balance assertion.
  def test_unclassified_movement_becomes_a_flagged_fixme_rather_than_vanishing
    block = transaction_block(
      convert, '2025-11-30 ! "Plata" "FIXME movimiento sin clasificar: Ajuste de custodia"'
    )

    assert_includes block, 'Assets:Investments:Plata:Cash  -3.00 USD'
    assert_includes block, 'Equity:FIXME'
  end

  def test_service_fees_matching_trade_commissions_are_not_double_counted
    refute_includes convert, 'cargo no reflejado en movimientos: comisiones por servicios'
  end

  def test_service_fees_exceeding_trade_commissions_are_flagged
    fees = [{ 'date' => '2025-11-25', 'description' => 'Asesoría', 'amount' => '20.00' }]
    io = StringIO.new
    build_converter(fixture_with('service_fees' => fees)).run_to(io)

    assert_includes io.string,
                    '2025-11-30 ! "Plata" ' \
                    '"FIXME cargo no reflejado en movimientos: comisiones por servicios"'
    assert_includes io.string, 'Assets:Investments:Plata:Cash  -14.74 USD'
  end

  def test_isr_withheld_items_are_flagged
    items = [{ 'date' => '2025-11-30', 'description' => 'Retención ISR', 'amount' => '12.00' }]
    io = StringIO.new
    build_converter(fixture_with('isr_withheld_items' => items)).run_to(io)

    assert_includes io.string, 'FIXME cargo no reflejado en movimientos: Retención ISR'
    assert_includes io.string, 'Assets:Investments:Plata:Cash  -12.00 USD'
  end

  def test_survives_an_unparseable_period_end
    period = { 'month_label' => '?', 'start_date' => '2025-11-01', 'end_date' => 'n/a' }
    io = StringIO.new
    build_converter(fixture_with('statement_period' => period)).run_to(io)

    refute_includes io.string, 'balance'
  end

  def test_emits_price_declarations_at_period_end
    content = convert

    assert_includes content, '2025-11-30 price NFLX  107.58 USD'
    assert_includes content, '2025-11-30 price VGK  81.53 USD'
  end

  def test_skips_price_declarations_with_missing_data
    refute_includes convert, 'NOPRICE'
  end

  def test_payee_is_stable_even_though_provider_string_changes
    # The advisor renamed itself from VestFi to Asesor en Inversiones Plata mid-2025.
    refute_includes convert, 'S.A.P.I.'
  end

  # `balance` asserts at the START of its date, so the closing figure has to be
  # dated the day after the period ends or the last day's movements fall outside it.
  def test_emits_cash_balance_assertion_dated_day_after_period_end
    assert_includes convert, '2025-12-01 balance Assets:Investments:Plata:Cash 2,897.15 USD'
  end

  def test_cash_balance_uses_thousands_separators
    refute_includes convert, 'Cash 2897.15 USD'
  end

  def test_cash_balance_comes_last
    assert_match(/balance Assets:Investments:Plata:Cash[^\n]*\n\z/, convert)
  end

  def test_cash_balance_rolls_over_year_end
    converter = build_converter(fixture_with('statement_period' => {
                                               'month_label' => 'Diciembre 2025',
                                               'start_date' => '2025-12-01',
                                               'end_date' => '2025-12-31'
                                             }))
    io = StringIO.new
    converter.run_to(io)

    assert_includes io.string, '2026-01-01 balance'
  end

  def test_skips_cash_balance_when_closing_figure_missing
    converter = build_converter(fixture_with('cash' => { 'current' => nil, 'previous' => '813.96' }))
    io = StringIO.new
    converter.run_to(io)

    refute_includes io.string, 'balance'
  end

  def test_run_to_writes_to_io
    io = StringIO.new
    converter.run_to(io)

    assert_includes io.string, '2025-11-25 * "Plata" "Compra VGK"'
    assert_includes io.string, '2025-11-30 price NFLX  107.58 USD'
  end

  def test_raises_without_input
    assert_raises ArgumentError do
      Frijolero::Converters::Plata.convert(input: nil, account: 'Test')
    end
  end

  def test_raises_without_account
    assert_raises ArgumentError do
      Frijolero::Converters::Plata.convert(input: 'test.json', account: nil)
    end
  end

  private

  def targets
    Frijolero::Converters::AccountTargets.new(
      counterpart: 'Assets:BBVA',
      dividend: 'Income:Dividends:Plata',
      interest: 'Income:Interest',
      tax: 'Expenses:Taxes:ISR',
      gains: 'Income:Gains:Plata',
      fees: 'Expenses:Fees:Plata',
      withholding: 'Expenses:Taxes:Withholding:USA'
    )
  end

  def converter
    Frijolero::Converters::Plata.new(
      input: fixture_path('sample_plata.json'),
      account: 'Assets:Investments:Plata',
      targets: targets
    )
  end

  # Writes a tweaked copy of the fixture to a temp file and returns a converter for it.
  def fixture_with(overrides)
    raw = File.read(fixture_path('sample_plata.json'), encoding: 'UTF-8')
    data = JSON.parse(raw).merge(overrides)
    path = File.join(@tmpdir ||= Dir.mktmpdir, 'statement.json')
    File.write(path, JSON.generate(data))
    path
  end

  def build_converter(path)
    Frijolero::Converters::Plata.new(
      input: path, account: 'Assets:Investments:Plata', targets: targets
    )
  end

  def convert
    @convert ||= begin
      io = StringIO.new
      converter.run_to(io)
      io.string
    end
  end

  # Returns just the postings belonging to one transaction header.
  def transaction_block(content, header)
    content.split("\n\n").find { |block| block.start_with?(header) } ||
      raise("transaction not found: #{header}")
  end
end
