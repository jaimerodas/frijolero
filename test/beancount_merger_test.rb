# frozen_string_literal: true

require 'test_helper'

class BeancountMergerTest < Minitest::Test
  include TestHelpers

  def test_appends_the_include_relative_to_the_main_file
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'main.beancount'), "; Main ledger\n")

      Frijolero::BeancountMerger.merge(File.join(dir, 'accounts', 'Amex', 'Amex 2501.beancount'))

      assert_equal "; Main ledger\ninclude \"accounts/Amex/Amex 2501.beancount\"\n",
                   File.read(File.join(dir, 'main.beancount'))
    end
  end

  def test_include_is_relative_to_main_file_in_subdirectory
    with_ledger_dir do |dir|
      with_env('LEDGER_MAIN_FILE' => 'ledger/main.beancount') do
        FileUtils.mkdir_p(File.join(dir, 'ledger'))

        Frijolero::BeancountMerger.merge(File.join(dir, 'accounts', 'Amex', 'Amex 2508.beancount'))

        assert_equal "include \"../accounts/Amex/Amex 2508.beancount\"\n",
                     File.read(File.join(dir, 'ledger', 'main.beancount'))
      end
    end
  end

  def test_skips_duplicate_include
    with_ledger_dir do |dir|
      main = File.join(dir, 'main.beancount')
      File.write(main, "include \"accounts/Amex/Amex 2501.beancount\"\n")

      Frijolero::BeancountMerger.merge(File.join(dir, 'accounts', 'Amex', 'Amex 2501.beancount'))

      assert_equal "include \"accounts/Amex/Amex 2501.beancount\"\n", File.read(main)
    end
  end
end
