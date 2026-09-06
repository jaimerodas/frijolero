# frozen_string_literal: true

require 'test_helper'

# Entry flattens the statement's four detail tables into one stream. The ordering
# guarantees are what let the converter group corporate actions by adjacency and
# keep reversal rows in the order the statement printed them.
class PlataEntryTest < Minitest::Test
  Entry = Frijolero::Converters::Plata::Entry

  def test_merges_all_four_tables
    stream = Entry.stream(
      'transactions' => [row('2025-11-02', 'Trade Entry')],
      'income' => [income_row('2025-11-03', 'Dividends')],
      'fees' => [{ 'trade_date' => '2025-11-04', 'description' => 'ADR', 'net_amount' => '-1.00' }],
      'deposits_withdrawals' => [income_row('2025-11-05', 'Journal Entry(Cash)')]
    )

    assert_equal %i[transaction income fee deposit_withdrawal], stream.map(&:source)
  end

  def test_sorts_by_date
    stream = Entry.stream(
      'transactions' => [row('2025-11-20', 'Trade Entry'), row('2025-11-02', 'Trade Entry')]
    )

    assert_equal %w[2025-11-02 2025-11-20], stream.map(&:date)
  end

  # Within one date the tables keep statement order: Transaction, Income, Fees,
  # Deposit & Withdrawals.
  def test_orders_tables_consistently_within_a_date
    stream = Entry.stream(
      'income' => [income_row('2025-11-03', 'Dividends')],
      'transactions' => [row('2025-11-03', 'Trade Entry')],
      'deposits_withdrawals' => [income_row('2025-11-03', 'Journal Entry(Cash)')]
    )

    assert_equal %i[transaction income deposit_withdrawal], stream.map(&:source)
  end

  # A dividend booked, reversed, and rebooked on the same date is three real rows.
  # Reordering them would make the reversal pair up with the wrong booking.
  def test_preserves_printed_order_of_same_date_rows
    stream = Entry.stream(
      'income' => [
        income_row('2025-11-13', 'Dividends', amount: '3.64'),
        income_row('2025-11-13', 'Dividends', amount: '-3.64'),
        income_row('2025-11-13', 'Dividends', amount: '3.64')
      ]
    )

    assert_equal(['3.64', '-3.64', '3.64'], stream.map { |e| format('%.2f', e.amount) })
  end

  def test_strips_the_footnote_asterisks_alpaca_appends_to_entry_types
    stream = Entry.stream('income' => [income_row('2025-11-30', 'Cash Interest**')])

    assert_equal 'Cash Interest', stream.first.entry_type
  end

  def test_fee_rows_get_a_synthetic_entry_type
    stream = Entry.stream(
      'fees' => [{ 'trade_date' => '2025-11-04', 'description' => 'ADR', 'net_amount' => '-1.00' }]
    )

    assert_equal 'Fee', stream.first.entry_type
    assert_equal(-1, stream.first.amount)
  end

  # Income, Fees and Deposit & Withdrawals name their money column "Net Amt";
  # the Transaction table calls it "Amount". Both land on #amount.
  def test_net_amount_becomes_amount
    stream = Entry.stream('income' => [income_row('2025-11-05', 'Dividends', amount: '3.90')])

    assert_equal BigDecimal('3.90'), stream.first.amount
  end

  def test_keeps_signed_quantities
    stream = Entry.stream('transactions' => [row('2025-11-25', 'Trade Entry', quantity: '-20')])

    assert_equal(-20, stream.first.quantity)
  end

  def test_treats_a_dash_symbol_as_no_symbol
    stream = Entry.stream('transactions' => [row('2025-11-05', 'High-Yield Cash Sweep', symbol: '-')])

    assert_nil stream.first.symbol
  end

  def test_handles_missing_tables
    assert_empty Entry.stream({})
  end

  def test_skips_rows_without_a_date
    stream = Entry.stream('income' => [income_row(nil, 'Dividends')])

    assert_empty stream
  end

  private

  def row(date, entry_type, quantity: nil, symbol: nil)
    {
      'trade_date' => date, 'entry_type' => entry_type, 'side' => nil, 'symbol' => symbol,
      'description' => nil, 'quantity' => quantity, 'price' => nil, 'amount' => nil,
      'commission' => nil
    }
  end

  def income_row(date, entry_type, amount: '1.00')
    {
      'trade_date' => date, 'entry_type' => entry_type, 'symbol' => nil,
      'description' => nil, 'net_amount' => amount
    }
  end
end
