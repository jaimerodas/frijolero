# frozen_string_literal: true

require "test_helper"

class UITest < Minitest::Test
  def teardown
    Frijolero::UI.auto_accept = false
  end

  def test_short_path_replaces_home_directory
    home = Dir.home
    assert_equal "~/Documents/file.txt", Frijolero::UI.short_path("#{home}/Documents/file.txt")
  end

  def test_short_path_leaves_non_home_paths_unchanged
    assert_equal "/tmp/file.txt", Frijolero::UI.short_path("/tmp/file.txt")
  end

  def test_short_path_handles_exact_home_directory
    home = Dir.home
    assert_equal "~", Frijolero::UI.short_path(home)
  end

  def test_format_number_with_commas
    assert_equal "12,345.67", Frijolero::UI.format_number(12345.67)
  end

  def test_format_number_small
    assert_equal "890.12", Frijolero::UI.format_number(890.12)
  end

  def test_format_number_large
    assert_equal "1,234,567.89", Frijolero::UI.format_number(1234567.89)
  end

  def test_format_number_zero
    assert_equal "0.00", Frijolero::UI.format_number(0)
  end

  def test_format_number_rounds_to_two_decimals
    assert_equal "100.46", Frijolero::UI.format_number(100.456)
  end

  def test_auto_accept_defaults_to_false
    assert_equal false, Frijolero::UI.auto_accept?
  end

  def test_auto_accept_can_be_set
    Frijolero::UI.auto_accept = true
    assert_equal true, Frijolero::UI.auto_accept?
  end

  def test_confirm_returns_true_when_auto_accept
    Frijolero::UI.auto_accept = true
    assert_equal true, Frijolero::UI.confirm("Test?")
  end
end
