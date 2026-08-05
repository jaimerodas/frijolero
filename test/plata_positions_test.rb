# frozen_string_literal: true

require 'test_helper'

# A statement reports closing share counts and every share movement of the period,
# so the opening position is recoverable: closing minus what moved. That is enough
# to tell a position that appeared this month from one that was already held, and a
# position that was emptied from one that merely shrank.
class PlataPositionsTest < Minitest::Test
  Positions = Frijolero::Converters::Plata::Positions
  Entry = Frijolero::Converters::Plata::Entry

  def test_a_position_bought_from_nothing_is_opened
    positions = build(holdings: [holding('MBGL', '5')], rows: [move('MBGL', '5')])

    assert_equal %w[MBGL], positions.opened
    assert_empty positions.closed
  end

  def test_a_position_that_was_already_held_is_not_opened
    positions = build(holdings: [holding('VGK', '15')], rows: [move('VGK', '10')])

    assert_empty positions.opened
  end

  # An exited position drops out of the Holdings table entirely, so its absence
  # there is the only signal that it went to zero.
  def test_a_position_sold_out_is_closed
    positions = build(holdings: [], rows: [move('EDV', '-27')])

    assert_equal %w[EDV], positions.closed
    assert_empty positions.opened
  end

  def test_a_position_bought_and_sold_within_the_month_is_both_opened_and_closed
    positions = build(holdings: [], rows: [move('TEMP', '5'), move('TEMP', '-5')])

    assert_equal %w[TEMP], positions.opened
    assert_equal %w[TEMP], positions.closed
  end

  def test_a_position_that_merely_shrank_is_left_alone
    positions = build(holdings: [holding('SPHD', '40')],
                      rows: [move('SPHD', '-15'), move('SPHD', '-10')])

    assert_empty positions.opened
    assert_empty positions.closed
  end

  def test_an_untouched_holding_is_left_alone
    positions = build(holdings: [holding('DIS', '12')], rows: [])

    assert_empty positions.opened
    assert_empty positions.closed
  end

  # A split removes the whole position and adds it back. The symbol is unchanged
  # throughout, so it must not look like an exit followed by a new position.
  def test_a_split_neither_opens_nor_closes_the_symbol
    positions = build(holdings: [holding('NFLX', '50')],
                      rows: [move('NFLX', '-5'), move('NFLX', '50')])

    assert_empty positions.opened
    assert_empty positions.closed
  end

  # The spinoff's source keeps its shares; only the target is new.
  def test_a_spinoff_opens_only_the_target
    positions = build(
      holdings: [holding('SPGI', '5'), holding('MBGL', '5')],
      rows: [move('MBGL', '5'), move('SPGI', '5'), move('SPGI', '-5')]
    )

    assert_equal %w[MBGL], positions.opened
    assert_empty positions.closed
  end

  # A dividend for a position exited in an earlier month carries no quantity, so it
  # must not be mistaken for share activity.
  def test_income_rows_do_not_count_as_share_movements
    positions = build(
      holdings: [],
      rows: [], income: [{ 'trade_date' => '2025-11-07', 'entry_type' => 'Dividends',
                           'symbol' => 'MA', 'net_amount' => '0.76' }]
    )

    assert_empty positions.opened
    assert_empty positions.closed
  end

  def test_results_are_sorted_for_stable_output
    positions = build(holdings: [holding('ZZZ', '1'), holding('AAA', '1')],
                      rows: [move('ZZZ', '1'), move('AAA', '1')])

    assert_equal %w[AAA ZZZ], positions.opened
  end

  def test_handles_an_empty_statement
    positions = build(holdings: [], rows: [])

    assert_empty positions.opened
    assert_empty positions.closed
  end

  private

  def build(holdings:, rows:, income: [])
    Positions.new(holdings, Entry.stream('transactions' => rows, 'income' => income))
  end

  def holding(symbol, quantity)
    { 'symbol' => symbol, 'quantity' => quantity }
  end

  def move(symbol, quantity)
    {
      'trade_date' => '2025-11-25', 'entry_type' => 'Trade Entry', 'symbol' => symbol,
      'quantity' => quantity, 'price' => '1.00', 'amount' => '1.00'
    }
  end
end
