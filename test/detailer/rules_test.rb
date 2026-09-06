# frozen_string_literal: true

require 'test_helper'

class DetailerRulesTest < Minitest::Test
  include TestHelpers

  def rules(config)
    Frijolero::Detailer::Rules.new(config)
  end

  def test_matches_a_start_with_pattern
    matched = rules('start_with' => { 'STARBUCKS' => { 'payee' => 'Starbucks' } })
              .matches_for(description: 'STARBUCKS REFORMA', amount: -80.0)

    assert_equal [{ 'payee' => 'Starbucks' }], matched
  end

  def test_does_not_match_a_start_with_pattern_found_mid_string
    matched = rules('start_with' => { 'REFORMA' => { 'payee' => 'Starbucks' } })
              .matches_for(description: 'STARBUCKS REFORMA', amount: -80.0)

    assert_empty matched
  end

  def test_matches_an_include_pattern_anywhere_in_the_description
    matched = rules('include' => { 'UBER' => { 'payee' => 'Uber' } })
              .matches_for(description: 'PAGO UBER TRIP', amount: -120.0)

    assert_equal [{ 'payee' => 'Uber' }], matched
  end

  def test_returns_start_with_rules_before_include_rules
    config = {
      'start_with' => { 'PAGO' => { 'payee' => 'Bank' } },
      'include' => { 'UBER' => { 'account' => 'Expenses:Transportation' } }
    }

    matched = rules(config).matches_for(description: 'PAGO UBER TRIP', amount: -120.0)

    assert_equal [{ 'payee' => 'Bank' }, { 'account' => 'Expenses:Transportation' }], matched
  end

  def test_returns_multiple_patterns_from_the_same_section_in_yaml_order
    config = {
      'start_with' => {
        'PAGO' => { 'payee' => 'Bank' },
        'PAGO UBER' => { 'payee' => 'Uber' }
      }
    }

    matched = rules(config).matches_for(description: 'PAGO UBER TRIP', amount: -120.0)

    assert_equal [{ 'payee' => 'Bank' }, { 'payee' => 'Uber' }], matched
  end

  def test_when_condition_selects_the_rule_with_the_matching_amount
    config = {
      'start_with' => {
        'TRANSFERENCIA' => [
          { 'when' => { 'amount' => -15_000 }, 'payee' => 'Landlord' },
          { 'when' => { 'amount' => -500 }, 'payee' => 'Gym' },
          { 'payee' => 'Transfer' }
        ]
      }
    }

    assert_equal 'Gym', rules(config).matches_for(description: 'TRANSFERENCIA X', amount: -500).first['payee']
  end

  def test_falls_back_to_the_entry_without_a_when_condition
    config = {
      'start_with' => {
        'TRANSFERENCIA' => [
          { 'when' => { 'amount' => -15_000 }, 'payee' => 'Landlord' },
          { 'payee' => 'Transfer' }
        ]
      }
    }

    assert_equal 'Transfer', rules(config).matches_for(description: 'TRANSFERENCIA X', amount: -42).first['payee']
  end

  def test_returns_nothing_when_no_when_condition_is_satisfied
    config = { 'start_with' => { 'NETFLIX' => { 'when' => { 'amount' => -149 }, 'payee' => 'Netflix' } } }

    assert_empty rules(config).matches_for(description: 'NETFLIX MX', amount: -199)
  end

  def test_compares_amounts_numerically_across_integer_float_and_string
    config = { 'start_with' => { 'NETFLIX' => { 'when' => { 'amount' => -149 }, 'payee' => 'Netflix' } } }

    ['-149.00', -149.0, -149, BigDecimal('-149')].each do |amount|
      refute_empty rules(config).matches_for(description: 'NETFLIX MX', amount: amount),
                   "expected #{amount.inspect} to match a `when: {amount: -149}` rule"
    end
  end

  # A beancount amount arrives as a string with fixed decimal places while the
  # YAML rule is written as a plain number; `==` alone never matches those.
  # (This is coercion, not float-drift immunity — BigDecimal(0.3.to_s) still
  # differs from BigDecimal((0.1 + 0.2).to_s).)
  def test_matches_a_string_amount_with_trailing_zeros_against_a_numeric_rule
    config = { 'start_with' => { 'TIP' => { 'when' => { 'amount' => -0.1 }, 'payee' => 'Tip' } } }

    refute_empty rules(config).matches_for(description: 'TIP JAR', amount: '-0.10')
  end

  def test_ignores_unknown_when_fields
    config = { 'start_with' => { 'NETFLIX' => { 'when' => { 'currency' => 'MXN' }, 'payee' => 'Netflix' } } }

    assert_empty rules(config).matches_for(description: 'NETFLIX MX', amount: -149)
  end

  def test_returns_nothing_for_a_missing_description
    config = { 'start_with' => { 'NETFLIX' => { 'payee' => 'Netflix' } } }

    assert_empty rules(config).matches_for(description: nil, amount: -149)
  end

  def test_tolerates_an_empty_config
    assert_empty rules(nil).matches_for(description: 'ANYTHING', amount: -1)
    assert_empty rules({}).matches_for(description: 'ANYTHING', amount: -1)
  end

  def test_loads_rules_from_a_yaml_file
    matched = Frijolero::Detailer::Rules.load(fixture_path('sample_detailer.yaml'))
                                        .matches_for(description: 'AMAZON WEB SERVICES', amount: -50.0)

    assert_equal 'Expenses:Subscriptions', matched.first['account']
  end
end
