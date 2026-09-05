# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class UITest < Minitest::Test
  def setup
    @sink = StringIO.new
    Frijolero::UI.sink = @sink
  end

  def teardown
    Frijolero::UI.auto_accept = false
    Frijolero::UI.sink = $stdout
  end

  def test_short_path_replaces_home_directory
    home = Dir.home
    assert_equal '~/Documents/file.txt', Frijolero::UI.short_path("#{home}/Documents/file.txt")
  end

  def test_short_path_leaves_non_home_paths_unchanged
    assert_equal '/tmp/file.txt', Frijolero::UI.short_path('/tmp/file.txt')
  end

  def test_short_path_handles_exact_home_directory
    home = Dir.home
    assert_equal '~', Frijolero::UI.short_path(home)
  end

  def test_format_number_with_commas
    assert_equal '12,345.67', Frijolero::UI.format_number(12_345.67)
  end

  def test_format_number_small
    assert_equal '890.12', Frijolero::UI.format_number(890.12)
  end

  def test_format_number_large
    assert_equal '1,234,567.89', Frijolero::UI.format_number(1_234_567.89)
  end

  def test_format_number_zero
    assert_equal '0.00', Frijolero::UI.format_number(0)
  end

  def test_format_number_rounds_to_two_decimals
    assert_equal '100.46', Frijolero::UI.format_number(100.456)
  end

  def test_auto_accept_defaults_to_false
    assert_equal false, Frijolero::UI.auto_accept?
  end

  def test_auto_accept_can_be_set
    Frijolero::UI.auto_accept = true
    assert_equal true, Frijolero::UI.auto_accept?
  end

  def test_puts_writes_to_sink_and_translates_glyphs
    Frijolero::UI.puts('{{x}} done')
    assert_equal "✗ done\n", @sink.string
  end

  def test_fmt_strips_color_markup
    assert_equal 'Error ✗ done', Frijolero::UI.fmt('{{red:Error}} {{x}} done')
  end

  def test_fmt_leaves_plain_text_unchanged
    assert_equal 'plain text', Frijolero::UI.fmt('plain text')
  end

  def test_frame_prints_title_and_runs_block
    ran = false
    Frijolero::UI.frame('Title') { ran = true }
    assert_equal "== Title\n", @sink.string
    assert ran
  end

  def test_spinner_prints_last_title_set_via_update_title
    Frijolero::UI.spinner('Working...') { |spinner| spinner.update_title('Done') }
    assert_equal "Done\n", @sink.string
  end

  def test_spinner_prints_initial_title_when_never_updated
    Frijolero::UI.spinner('Working...') { |spinner| spinner }
    assert_equal "Working...\n", @sink.string
  end

  def test_confirm_returns_false_when_auto_accept_is_false
    assert_equal false, Frijolero::UI.confirm('Test?')
  end

  def test_confirm_returns_true_when_auto_accept_is_true
    Frijolero::UI.auto_accept = true
    assert_equal true, Frijolero::UI.confirm('Test?')
  end

  def test_detailer_stats_prints_debit_and_credit_summary_lines
    stats = {
      detailed: [{ 'amount' => -100 }],
      remaining: [{ 'amount' => 50 }]
    }
    Frijolero::UI.detailer_stats(stats)
    assert_equal "1 detailed: 1 debits (100.00)\n1 remaining: 1 credits (50.00)\n", @sink.string
  end
end
