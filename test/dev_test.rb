# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'

class DevTest < Minitest::Test
  include TestHelpers

  SCRIPT = File.expand_path('../bin/dev', __dir__)

  # bin/dev stops before puma when the main file is not there, and names the fix.
  def test_refuses_a_ledger_without_the_main_file
    with_temp_dir do |tmp|
      File.write(File.join(tmp, 'ledger.beancount'), '')
      _out, err, status = Open3.capture3({ 'LEDGER_DIR' => tmp, 'LEDGER_MAIN_FILE' => nil }, SCRIPT)

      refute_predicate status, :success?
      assert_includes err, 'main.beancount'
      assert_includes err, 'LEDGER_MAIN_FILE'
      assert_includes err, 'ledger.beancount'
    end
  end
end
