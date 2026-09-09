# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'

class NewLedgerTest < Minitest::Test
  include TestHelpers

  SCRIPT = File.expand_path('../bin/new-ledger', __dir__)
  FILES = %w[transactions.beancount moneys.beancount account_opens.beancount balances.beancount
             prices.beancount config/accounts.yaml config/prompts/default/spec.json
             config/prompts/classify/schema.json config/rules/.gitkeep accounts/.gitkeep .gitignore].freeze

  def test_creates_the_files_and_a_first_commit
    with_temp_dir do |tmp|
      dir = File.join(tmp, 'ledger')
      out, err, status = Open3.capture3(scrubbed_env, SCRIPT, dir)

      assert_predicate status, :success?, err
      FILES.each { |file| assert_path_exists File.join(dir, file) }
      log, = Open3.capture2(scrubbed_env, 'git', '-C', dir, 'log', '--oneline')
      assert_equal 1, log.lines.size
      assert_includes out, 'remote add origin'
    end
  end

  def test_the_app_reads_the_new_ledger_as_empty
    with_temp_dir do |tmp|
      dir = File.join(tmp, 'ledger')
      Open3.capture3(scrubbed_env, SCRIPT, dir)

      ENV['LEDGER_DIR'] = dir
      assert_empty Frijolero::Config.accounts
    ensure
      ENV.delete('LEDGER_DIR')
    end
  end

  def test_refuses_an_existing_directory
    with_temp_dir do |tmp|
      _out, err, status = Open3.capture3(scrubbed_env, SCRIPT, tmp)

      refute_predicate status, :success?
      assert_includes err, 'ya existe'
    end
  end

  private

  # A git hook exports GIT_DIR and friends. Scrubbed, or the script commits to this repo.
  def scrubbed_env
    ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
  end
end
