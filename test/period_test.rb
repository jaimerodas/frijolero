# frozen_string_literal: true

require 'test_helper'

class PeriodTest < Minitest::Test
  Period = Frijolero::Period

  FIRST = Date.new(2024, 12, 1)
  TODAY = Date.new(2026, 9, 9)

  def parse(param)
    Period.parse(param, first: FIRST, today: TODAY)
  end

  def test_parses_each_resolution_with_its_bounds_label_and_param
    cases = {
      'all' => [:all, FIRST, TODAY, 'Todo'],
      '2026' => [:year, Date.new(2026, 1, 1), Date.new(2026, 12, 31), '2026'],
      '2026-T3' => [:quarter, Date.new(2026, 7, 1), Date.new(2026, 9, 30), 'T3 2026'],
      '2026-09' => [:month, Date.new(2026, 9, 1), Date.new(2026, 9, 30), 'septiembre 2026']
    }
    cases.each do |param, (resolution, from, to, label)|
      period = parse(param)

      assert_equal [resolution, from, to, label, param],
                   [period.resolution, period.from, period.to, period.label, period.param]
    end
  end

  def test_rejects_what_is_not_a_period
    assert_nil parse('2026-13')
    assert_nil parse('2026-T5')
    assert_nil parse('nope')
    assert_nil parse(nil)
  end

  def test_switching_resolution_keeps_the_anchor_date
    assert_equal '2026-09', parse('2026').at(:month, first: FIRST, today: TODAY).param
    assert_equal '2024-12', parse('2024').at(:month, first: FIRST, today: TODAY).param
    assert_equal '2026-T1', parse('2026-02').at(:quarter, first: FIRST, today: TODAY).param
    assert_equal 'all', parse('2026-02').at(:all, first: FIRST, today: TODAY).param
  end

  def test_neighbours_stop_at_the_ledger_bounds
    assert_equal '2026-08', parse('2026-09').prev(first: FIRST).param
    assert_nil parse('2026-09').next(today: TODAY)
    assert_equal '2025', parse('2024').next(today: TODAY).param
    assert_nil parse('2024-12').prev(first: FIRST)
    assert_nil parse('all').prev(first: FIRST)
  end

  def test_siblings_list_every_period_in_the_ledger_newest_first
    assert_equal %w[2026 2025 2024], parse('2025').siblings(first: FIRST, today: TODAY).map(&:param)
    assert_equal 8, parse('2026-T1').siblings(first: FIRST, today: TODAY).size
    assert_equal '2024-12', parse('2026-01').siblings(first: FIRST, today: TODAY).last.param
    assert_equal ['all'], parse('all').siblings(first: FIRST, today: TODAY).map(&:param)
  end
end
