# frozen_string_literal: true

require 'test_helper'

class UnitReconcilerTest < Minitest::Test
  def test_no_mismatch_when_units_unchanged_and_untraded
    assert_empty reconcile([holding('AAPL', current: '14', previous: '14')], [])
  end

  def test_no_mismatch_when_buys_explain_the_change
    mismatches = reconcile(
      [holding('VGK', current: '15', previous: '5')],
      [trade('buy', 'VGK', '10')]
    )

    assert_empty mismatches
  end

  def test_no_mismatch_when_sells_explain_the_change
    mismatches = reconcile(
      [holding('AAPL', current: '10', previous: '14')],
      [trade('sell', 'AAPL', '4')]
    )

    assert_empty mismatches
  end

  def test_detects_split_hidden_behind_a_sale
    # NFLX November 2025: 5 held, 20 sold, 30 reported. A 10:1 split with no row.
    mismatch = reconcile(
      [holding('NFLX', current: '30', previous: '5')],
      [trade('sell', 'NFLX', '20')]
    ).first

    assert_equal 'NFLX', mismatch.ticker
    assert_equal(-15, mismatch.expected)
    assert_equal 30, mismatch.reported
    assert_equal 45, mismatch.delta
  end

  def test_nets_multiple_trades_of_the_same_ticker
    mismatches = reconcile(
      [holding('VT', current: '113', previous: '110')],
      [trade('buy', 'VT', '5'), trade('sell', 'VT', '2')]
    )

    assert_empty mismatches
  end

  def test_dividends_do_not_affect_unit_counts
    mismatches = reconcile(
      [holding('BND', current: '16', previous: '16')],
      [{ 'ticker' => 'BND', 'transaction_type' => 'dividend', 'amount' => '3.51' }]
    )

    assert_empty mismatches
  end

  def test_strips_thousands_separators_from_unit_counts
    mismatches = reconcile(
      [holding('SCHH', current: '1,385', previous: '385')],
      [trade('buy', 'SCHH', '1,000')]
    )

    assert_empty mismatches
  end

  # Alpaca custody allows fractional shares. Under Float, 0.1 + 0.2 != 0.3 and this
  # reconciling holding produced a delta of -5.55e-17 -- which then rendered in
  # scientific notation and made the whole ledger unparseable.
  def test_fractional_shares_that_reconcile_produce_no_mismatch
    mismatches = reconcile(
      [holding('VOO', current: '0.3', previous: '0.1')],
      [trade('buy', 'VOO', '0.2')]
    )

    assert_empty mismatches
  end

  def test_fractional_shares_that_genuinely_differ_are_still_caught
    mismatch = reconcile(
      [holding('VOO', current: '0.5', previous: '0.1')],
      [trade('buy', 'VOO', '0.2')]
    ).first

    assert_in_delta 0.2, mismatch.delta.to_f, 1e-9
  end

  def test_skips_holdings_without_a_ticker
    assert_empty reconcile([holding(nil, current: '10', previous: '1')], [])
  end

  def test_handles_missing_holdings_and_transactions
    assert_empty Frijolero::Converters::UnitReconciler.new(nil, nil).mismatches
  end

  private

  def reconcile(holdings, transactions)
    Frijolero::Converters::UnitReconciler.new(holdings, transactions).mismatches
  end

  def holding(ticker, current:, previous:)
    { 'ticker' => ticker, 'units_current' => current, 'units_previous' => previous }
  end

  def trade(type, ticker, units)
    { 'ticker' => ticker, 'transaction_type' => type, 'units' => units }
  end
end
