# frozen_string_literal: true

require 'test_helper'

# Splits and spinoffs conserve cost basis: the shares removed and the shares added
# are the same money. Alpaca prints a rounded per-share price on the new side, so
# the removed total is what the additions have to be reconciled against.
class PlataCorporateActionTest < Minitest::Test
  CorporateAction = Frijolero::Converters::Plata::CorporateAction
  Entry = Frijolero::Converters::Plata::Entry

  # NFLX 5 @ 480.46 = 2402.30 becomes 50 @ 48.05, which multiplies back to
  # 2402.50. Trusting the printed price would invent 20 cents of basis.
  def test_split_takes_the_addition_total_from_the_removed_basis
    action = build(
      leg('NFLX', '-5', '480.46'),
      leg('NFLX', '50', '48.05')
    )

    assert_equal BigDecimal('2402.30'), action.removed_total
    assert_equal [BigDecimal('2402.30')], action.added_legs.map(&:total)
  end

  def test_split_narration_names_the_single_symbol
    action = build(leg('NFLX', '-5', '480.46'), leg('NFLX', '50', '48.05'))

    assert_equal 'Stock Split NFLX', action.narration
  end

  # SPGI 5 @ 342.04 = 1710.20 splits into SPGI 5 @ 324.47 = 1622.35 and
  # MBGL 5 @ 17.57 = 87.85, which happens to add up exactly.
  def test_spinoff_allocates_basis_across_both_symbols
    action = build(
      leg('MBGL', '5', '17.57', 'Stock SpinOff'),
      leg('SPGI', '5', '324.47', 'Stock SpinOff'),
      leg('SPGI', '-5', '342.04', 'Stock SpinOff')
    )

    assert_equal BigDecimal('1710.20'), action.removed_total
    assert_equal [BigDecimal('87.85'), BigDecimal('1622.35')],
                 action.added_legs.sort_by(&:total).map(&:total)
  end

  def test_spinoff_narration_names_source_and_target
    action = build(
      leg('MBGL', '5', '17.57', 'Stock SpinOff'),
      leg('SPGI', '5', '324.47', 'Stock SpinOff'),
      leg('SPGI', '-5', '342.04', 'Stock SpinOff')
    )

    assert_equal 'Stock SpinOff SPGI -> MBGL', action.narration
  end

  # The residue from rounding has to land somewhere. It goes on the largest leg,
  # where it is proportionally smallest.
  def test_the_largest_addition_absorbs_the_rounding_residue
    action = build(
      leg('SMALL', '1', '10.00', 'Stock SpinOff'),
      leg('BIG', '1', '90.00', 'Stock SpinOff'),
      leg('BIG', '-1', '100.11', 'Stock SpinOff')
    )
    totals = action.added_legs.to_h { |leg| [leg.symbol, leg.total] }

    assert_equal BigDecimal('10.00'), totals['SMALL']
    assert_equal BigDecimal('90.11'), totals['BIG']
  end

  def test_additions_always_sum_to_the_removed_basis
    action = build(
      leg('A', '3', '3.33', 'Stock SpinOff'),
      leg('B', '3', '6.66', 'Stock SpinOff'),
      leg('B', '-3', '10.00', 'Stock SpinOff')
    )

    assert_equal action.removed_total, action.added_legs.sum(&:total)
  end

  def test_removed_legs_keep_their_negative_quantities
    action = build(leg('NFLX', '-5', '480.46'), leg('NFLX', '50', '48.05'))

    assert_equal [BigDecimal('-5')], action.removed_legs.map(&:quantity)
  end

  def test_collects_the_statement_descriptions_for_the_audit_comment
    action = build(
      leg('NFLX', '-5', '480.46', 'Stock Split', 'REMOVE, Position Value:2402.3'),
      leg('NFLX', '50', '48.05', 'Stock Split', 'ADD, Position Value:2402.3')
    )

    assert_equal ['REMOVE, Position Value:2402.3', 'ADD, Position Value:2402.3'],
                 action.descriptions
  end

  def test_deduplicates_identical_descriptions
    action = build(
      leg('NFLX', '-5', '480.46', 'Stock Split', 'same'),
      leg('NFLX', '50', '48.05', 'Stock Split', 'same')
    )

    assert_equal ['same'], action.descriptions
  end

  # A removal with nothing added cannot balance on its own. The converter needs to
  # know so it can flag the transaction instead of emitting an unparseable file.
  def test_a_removal_with_no_additions_is_not_balanced
    action = build(leg('DEAD', '-5', '10.00'))

    refute_predicate action, :balanced?
  end

  def test_a_matched_pair_is_balanced
    action = build(leg('NFLX', '-5', '480.46'), leg('NFLX', '50', '48.05'))

    assert_predicate action, :balanced?
  end

  private

  def build(*rows)
    CorporateAction.new(Entry.stream('transactions' => rows))
  end

  def leg(symbol, quantity, price, entry_type = 'Stock Split', description = nil)
    {
      'trade_date' => '2025-11-17', 'entry_type' => entry_type, 'side' => nil,
      'symbol' => symbol, 'description' => description, 'quantity' => quantity,
      'price' => price, 'amount' => nil, 'commission' => nil
    }
  end
end
