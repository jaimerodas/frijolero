# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class LogTest < Minitest::Test
  include TestHelpers

  def setup
    @sink = StringIO.new
    Frijolero::Log.sink = @sink
  end

  def teardown
    Frijolero::Log.sink = $stdout
  end

  def test_short_path_is_relative_to_the_ledger
    with_ledger_dir do |dir|
      path = File.join(dir, 'accounts/AMEX/AMEX 2508.json')
      assert_equal 'accounts/AMEX/AMEX 2508.json', Frijolero::Log.short_path(path)
    end
  end

  def test_short_path_leaves_a_path_outside_the_ledger_unchanged
    with_ledger_dir { assert_equal '/tmp/file.txt', Frijolero::Log.short_path('/tmp/file.txt') }
  end

  def test_format_number_with_commas
    assert_equal '12,345.67', Frijolero::Log.format_number(12_345.67)
  end

  def test_format_number_small
    assert_equal '890.12', Frijolero::Log.format_number(890.12)
  end

  def test_format_number_large
    assert_equal '1,234,567.89', Frijolero::Log.format_number(1_234_567.89)
  end

  def test_format_number_zero
    assert_equal '0.00', Frijolero::Log.format_number(0)
  end

  def test_format_number_rounds_to_two_decimals
    assert_equal '100.46', Frijolero::Log.format_number(100.456)
  end

  def test_puts_writes_to_the_sink
    Frijolero::Log.puts('✗ done')
    assert_equal "✗ done\n", @sink.string
  end

  def test_detailer_stats_prints_debit_and_credit_summary_lines
    stats = {
      detailed: [{ 'amount' => -100 }],
      remaining: [{ 'amount' => 50 }]
    }
    Frijolero::Log.detailer_stats(stats)
    assert_equal "1 detailed: 1 debits (100.00)\n1 remaining: 1 credits (50.00)\n", @sink.string
  end
end
