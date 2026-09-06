# frozen_string_literal: true

require 'test_helper'

class PlataConverterTest < Minitest::Test
  include TestHelpers

  # --- trades ---------------------------------------------------------------

  # The statement's Amount column is authoritative: 10 x 79.59 = 795.90, but the
  # statement reports 795.91. Total-cost syntax keeps the ledger balanced.
  def test_buy_uses_total_cost_not_rounded_unit_price
    block = transaction_block(convert, '2025-11-25 * "Plata" "Buy VGK"')

    assert_includes block, 'Assets:Investments:Plata:VGK  10 VGK {{795.91 USD}}'
    refute_includes block, '{79.59 USD}'
  end

  def test_buy_expenses_commission_and_debits_cash_including_it
    block = transaction_block(convert, '2025-11-25 * "Plata" "Buy VGK"')

    assert_includes block, 'Expenses:Fees:Plata  1.43 USD'
    assert_includes block, 'Assets:Investments:Plata:Cash  -797.34 USD'
  end

  def test_sell_credits_cash_net_of_commission_and_books_gains
    block = transaction_block(convert, '2025-11-25 * "Plata" "Sell NFLX"')

    assert_includes block, 'Assets:Investments:Plata:NFLX  -20 NFLX {} @@ 2133.20 USD'
    assert_includes block, 'Expenses:Fees:Plata  3.83 USD'
    assert_includes block, 'Assets:Investments:Plata:Cash  2129.37 USD'
    assert_includes block, 'Income:Gains:Plata'
  end

  # The statement prints sells with a negative Quantity. Taking its absolute value
  # would add shares on a sale.
  def test_sell_keeps_the_statements_negative_quantity
    refute_includes convert, 'Assets:Investments:Plata:NFLX  20 NFLX'
  end

  # --- corporate actions ----------------------------------------------------

  # 5 NFLX at 480.46 become 50 at 48.05. The printed new price is rounded --
  # 50 x 48.05 = 2402.50 against a removed basis of 2402.30 -- so the ADD takes
  # its total from the REMOVE side and the split conserves basis exactly.
  def test_split_conserves_cost_basis_against_the_rounded_new_price
    block = transaction_block(convert, '2025-11-17 * "Plata" "Stock Split NFLX"')

    assert_includes block, 'Assets:Investments:Plata:NFLX  -5 NFLX {}'
    assert_includes block, 'Assets:Investments:Plata:NFLX  50 NFLX {{2402.30 USD}}'
    refute_includes block, '2402.50'
  end

  def test_split_needs_no_equity_plug
    block = transaction_block(convert, '2025-11-17 * "Plata" "Stock Split NFLX"')

    refute_includes block, 'Equity:FIXME'
    refute_includes block, 'Income:Gains'
  end

  def test_split_keeps_the_statement_description_as_a_comment
    block = transaction_block(convert, '2025-11-17 * "Plata" "Stock Split NFLX"')

    assert_includes block, '; REMOVE, From QTY:-5, To QTY:50, Position Value:2402.3'
  end

  # SPGI 5 @ 342.04 = 1710.20 becomes SPGI 5 @ 324.47 = 1622.35 plus MBGL
  # 5 @ 17.57 = 87.85. Basis is conserved to the cent.
  def test_spinoff_splits_basis_between_source_and_target
    block = transaction_block(convert, '2025-11-20 * "Plata" "Stock SpinOff SPGI -> MBGL"')

    assert_includes block, 'Assets:Investments:Plata:SPGI  -5 SPGI {}'
    assert_includes block, 'Assets:Investments:Plata:SPGI  5 SPGI {{1622.35 USD}}'
    assert_includes block, 'Assets:Investments:Plata:MBGL  5 MBGL {{87.85 USD}}'
  end

  # The spinoff's target row carries neither "ADD" nor "REMOVE" in its description,
  # so the sign of Quantity is what separates the two sides.
  def test_spinoff_classifies_rows_by_quantity_sign_not_description_keyword
    block = transaction_block(convert, '2025-11-20 * "Plata" "Stock SpinOff SPGI -> MBGL"')

    assert_equal 1, block.scan('-5 SPGI').size
    assert_includes block, '5 MBGL {{87.85 USD}}'
  end

  def test_corporate_action_removals_come_before_additions
    block = transaction_block(convert, '2025-11-20 * "Plata" "Stock SpinOff SPGI -> MBGL"')
    postings = block.lines.grep(/Assets:Investments/)

    assert_match(/-5 SPGI/, postings.first)
  end

  # --- transfers ------------------------------------------------------------

  def test_acats_securities_carry_their_cost_basis_against_opening_balances
    block = transaction_block(convert, '2025-11-03 * "Plata" "ACAT Transfer 20250270052117"')

    assert_includes block, 'Assets:Investments:Plata:AMZN  15 AMZN {154.53 USD}'
    assert_includes block, 'Equity:Opening-Balances'
  end

  def test_acats_cash_books_against_opening_balances
    content = convert

    assert_includes content, 'Assets:Investments:Plata:Cash  79.69 USD'
    assert_equal 2, content.scan('Equity:Opening-Balances').size
  end

  # --- income ---------------------------------------------------------------

  # Alpaca reports the gross dividend and the withholding as separate rows, unlike
  # the advisor statement which reported the dividend already net.
  def test_dividend_books_the_gross_amount
    block = transaction_block(convert, '2025-11-05 * "Plata" "Dividend BND"')

    assert_includes block, 'Assets:Investments:Plata:Cash  3.90 USD'
    assert_includes block, 'Income:Dividends:Plata  -3.90 USD'
  end

  def test_withholding_is_its_own_transaction
    block = transaction_block(convert, '2025-11-05 * "Plata" "Withholding BND"')

    assert_includes block, 'Assets:Investments:Plata:Cash  -0.39 USD'
    assert_includes block, 'Expenses:Taxes:Withholding:USA  0.39 USD'
  end

  # 2025-11-13 AAPL is booked, reversed, and rebooked. Netting or deduplicating
  # the rows would silently drop a real pair of movements.
  def test_dividend_reversals_survive_as_three_separate_transactions
    content = convert

    assert_equal 3, content.scan('* "Plata" "Dividend AAPL"').size
    assert_includes content, 'Assets:Investments:Plata:Cash  -3.64 USD'
    assert_includes content, 'Income:Dividends:Plata  3.64 USD'
  end

  def test_withholding_reversal_flips_both_postings
    content = convert

    assert_equal 3, content.scan('* "Plata" "Withholding AAPL"').size
    assert_includes content, 'Assets:Investments:Plata:Cash  0.36 USD'
    assert_includes content, 'Expenses:Taxes:Withholding:USA  -0.36 USD'
  end

  def test_cash_interest_books_to_the_interest_account
    block = transaction_block(convert, '2025-11-30 * "Plata" "Cash Interest"')

    assert_includes block, 'Assets:Investments:Plata:Cash  1.27 USD'
    assert_includes block, 'Income:Interest  -1.27 USD'
  end

  def test_fee_rows_debit_cash_and_expense_the_fee
    block = transaction_block(convert, '2025-11-29 * "Plata" "ADR pass-through fee"')

    assert_includes block, 'Assets:Investments:Plata:Cash  -2.50 USD'
    assert_includes block, 'Expenses:Fees:Plata  2.50 USD'
  end

  # --- journal entries ------------------------------------------------------

  # The counterpart is genuinely unknowable from the statement, so these land on
  # Expenses:FIXME flagged `*` -- which is exactly what BeancountDetailer rewrites
  # when `frijolero detail` is later run against the converted file.
  def test_journal_entry_lands_on_fixme_flagged_for_the_detailer
    block = transaction_block(
      convert,
      '2025-11-10 * "Plata" "Journal Entry: NRA withholding refund - Income Reallocation"'
    )

    assert_includes block, 'Assets:Investments:Plata:Cash  20.54 USD'
    assert_includes block, 'Expenses:FIXME'
  end

  # --- sweeps ---------------------------------------------------------------

  # Sweep rows move cash between the brokerage and the FDIC partner banks. They are
  # absent from the Cash Summary, so emitting them would double-count.
  def test_cash_sweep_rows_are_not_emitted
    content = convert

    refute_includes content, 'Cash  -50.00 USD'
    refute_includes content, 'Cash  30.00 USD'
  end

  def test_ignored_sweep_rows_are_reported_in_the_header
    assert_includes convert, '; 2 High-Yield Cash Sweep rows ignored (internal transfers)'
  end

  # --- unknown entry types --------------------------------------------------

  # Dropping a row we cannot classify would take its cash movement with it, and the
  # only symptom would be a failed balance assertion with nothing to point at.
  def test_unknown_entry_type_becomes_a_flagged_fixme_rather_than_vanishing
    block = transaction_block(
      convert, '2025-11-30 ! "Plata" "FIXME unclassified entry: Custody Adjustment"'
    )

    assert_includes block, 'Assets:Investments:Plata:Cash  -3.00 USD'
    assert_includes block, 'Equity:FIXME'
  end

  # --- account lifecycle ----------------------------------------------------

  # AMZN arrives by ACATS and MBGL is spun off; neither existed before this month.
  def test_opens_accounts_for_positions_that_appear
    content = convert

    assert_includes content, '2025-11-01 open Assets:Investments:Plata:AMZN AMZN "FIFO"'
    assert_includes content, '2025-11-01 open Assets:Investments:Plata:MBGL MBGL "FIFO"'
  end

  # `{}` reductions are ambiguous under STRICT booking once a ticker has two lots,
  # which a split guarantees, so the booking method is not optional.
  def test_opens_declare_fifo_booking
    refute_match(/open Assets:Investments:Plata:\w+ \w+$/, convert)
  end

  def test_does_not_open_positions_that_were_already_held
    content = convert

    refute_includes content, 'open Assets:Investments:Plata:AAPL'
    refute_includes content, 'open Assets:Investments:Plata:NFLX'
    refute_includes content, 'open Assets:Investments:Plata:VGK'
  end

  # A split removes the whole position and adds it back under a new cost price. The
  # symbol never left, so it must not read as an exit plus a new position.
  def test_a_split_neither_opens_nor_closes_its_symbol
    content = convert

    refute_includes content, 'open Assets:Investments:Plata:NFLX'
    refute_includes content, 'close Assets:Investments:Plata:NFLX'
  end

  # EDV is sold out entirely and so disappears from the Holdings table.
  def test_closes_accounts_for_positions_that_are_emptied
    assert_includes convert, '2025-12-01 close Assets:Investments:Plata:EDV'
  end

  def test_does_not_close_positions_that_merely_shrank
    refute_includes convert, 'close Assets:Investments:Plata:VGK'
  end

  # TEMP is bought and sold within the month, so it needs both directives or the
  # account is never declared at all.
  def test_a_position_bought_and_sold_in_one_month_is_opened_and_closed
    content = convert

    assert_includes content, '2025-11-01 open Assets:Investments:Plata:TEMP TEMP "FIFO"'
    assert_includes content, '2025-12-01 close Assets:Investments:Plata:TEMP'
  end

  # An `open` only has to precede the account's first posting; period start always
  # does, without having to hunt for that posting.
  def test_opens_precede_the_transactions
    content = convert
    first_open = content.index('open Assets:Investments:Plata')
    first_transaction = content.index('* "Plata"')

    assert_operator first_open, :<, first_transaction
  end

  def test_closes_come_last
    assert_match(/close Assets:Investments:Plata:\w+\n\z/, convert)
  end

  def test_skips_opens_when_the_period_start_is_unparseable
    content = convert_with('statement_period' => {
                             'month_label' => '?', 'start_date' => 'n/a',
                             'end_date' => '2025-11-30'
                           })

    refute_includes content, ' open '
  end

  # --- the reconciliation property ------------------------------------------

  # The whole design rests on the Alpaca statement reconciling exactly. If the
  # emitted cash postings ever stop summing to the statement's own movement in
  # cash, something has been dropped, doubled, or mis-signed.
  def test_emitted_cash_postings_sum_to_the_statements_cash_movement
    postings = convert.scan(/^ {2}Assets:Investments:Plata:Cash {2}(-?[\d.]+) USD$/).flatten
    total = postings.sum { |amount| BigDecimal(amount) }

    assert_equal BigDecimal('3046.97'), total
    assert_equal BigDecimal('3860.93'), BigDecimal('813.96') + total
  end

  # --- period-end directives ------------------------------------------------

  def test_emits_price_declarations_at_period_end
    content = convert

    assert_includes content, '2025-11-30 price NFLX  107.58 USD'
    assert_includes content, '2025-11-30 price VGK  81.53 USD'
  end

  def test_skips_price_declarations_with_missing_data
    refute_includes convert, 'price NOPRICE'
  end

  # `balance` asserts at the START of its date, so the closing figures have to be
  # dated the day after the period ends or the last day's movements fall outside.
  def test_emits_cash_balance_assertion_dated_day_after_period_end
    assert_includes convert, '2025-12-01 balance Assets:Investments:Plata:Cash  3,860.93 USD'
  end

  def test_cash_balance_uses_thousands_separators
    refute_includes convert, 'Cash  3860.93 USD'
  end

  # Every closing share count is now reported, so beancount can police share drift
  # directly -- which is what replaced the old UnitReconciler guesswork.
  def test_emits_a_balance_assertion_for_every_holding
    content = convert

    assert_includes content, '2025-12-01 balance Assets:Investments:Plata:NFLX  30 NFLX'
    assert_includes content, '2025-12-01 balance Assets:Investments:Plata:MBGL  5 MBGL'
    assert_includes content, '2025-12-01 balance Assets:Investments:Plata:VGK  15 VGK'
    assert_equal 8, content.scan(/balance Assets:Investments:Plata:(?!Cash)/).size
  end

  # A close takes effect on its date, so every assertion it could invalidate has to
  # be stated before it.
  def test_balance_assertions_precede_the_closes
    content = convert

    assert_operator content.rindex(' balance '), :<, content.index(' close ')
  end

  def test_cash_balance_rolls_over_year_end
    content = convert_with('statement_period' => {
                             'month_label' => 'DECEMBER - 2025',
                             'start_date' => '2025-12-01',
                             'end_date' => '2025-12-31'
                           })

    assert_includes content, '2026-01-01 balance'
  end

  def test_survives_an_unparseable_period_end
    content = convert_with('statement_period' => {
                             'month_label' => '?', 'start_date' => '2025-11-01',
                             'end_date' => 'n/a'
                           })

    refute_includes content, 'balance'
    refute_includes content, ' price '
  end

  def test_falls_back_to_the_cash_holding_row_when_the_summary_is_missing
    content = convert_with('cash_summary' => { 'ending_value' => nil })

    assert_includes content, 'balance Assets:Investments:Plata:Cash  3,860.93 USD'
  end

  def test_skips_cash_balance_when_no_closing_figure_is_available
    content = convert_with('cash_summary' => { 'ending_value' => nil },
                           'cash_holding' => { 'market_value' => nil })

    refute_includes content, 'balance Assets:Investments:Plata:Cash'
  end

  # --- header ---------------------------------------------------------------

  def test_header_records_the_period_and_provider
    content = convert

    assert_includes content, '; Alpaca statement 2025-11-01..2025-11-30'
    assert_includes content, 'Asesor en Inversiones Plata, S.A.P.I. de C.V.'
  end

  def test_header_restates_the_cash_summary_for_auditing
    assert_includes convert, '; Cash: 813.96 + 113.04 - 7.75 + 2952.71 + -11.03 = 3860.93'
  end

  def test_header_records_realized_gain_loss
    assert_includes convert, '; Realized gain/loss this period: short 447.34, long 0.00'
  end

  # The advisor renamed itself mid-2025; the payee must not track that.
  def test_payee_is_stable_even_though_provider_string_changes
    refute_match(/^\d{4}-\d\d-\d\d [*!] "[^"]*S\.A\.P\.I/, convert)
  end

  # --- contract -------------------------------------------------------------

  def test_run_to_writes_to_io
    io = StringIO.new
    converter.run_to(io)

    assert_includes io.string, '2025-11-25 * "Plata" "Buy VGK"'
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
      dividend: 'Income:Dividends:Plata',
      interest: 'Income:Interest',
      gains: 'Income:Gains:Plata',
      fees: 'Expenses:Fees:Plata',
      withholding: 'Expenses:Taxes:Withholding:USA'
    )
  end

  def converter(input = fixture_path('sample_plata.json'))
    Frijolero::Converters::Plata.new(
      input: input, account: 'Assets:Investments:Plata', targets: targets
    )
  end

  def convert
    @convert ||= run_converter(converter)
  end

  # Merges overrides into a copy of the fixture (one level deep) and converts that.
  def convert_with(overrides)
    data = JSON.parse(File.read(fixture_path('sample_plata.json'), encoding: 'UTF-8'))
    overrides.each do |key, value|
      data[key] = data[key].is_a?(Hash) ? data[key].merge(value) : value
    end
    path = File.join(@tmpdir ||= Dir.mktmpdir, 'statement.json')
    File.write(path, JSON.generate(data))
    run_converter(converter(path))
  end

  def run_converter(instance)
    io = StringIO.new
    instance.run_to(io)
    io.string
  end

  # Returns just the header and postings belonging to one transaction.
  def transaction_block(content, header)
    content.split("\n\n").find { |block| block.start_with?(header) } ||
      raise("transaction not found: #{header}")
  end
end
