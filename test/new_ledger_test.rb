# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'

class NewLedgerTest < Minitest::Test
  include TestHelpers

  SCRIPT = File.expand_path('../bin/new-ledger', __dir__)
  FILES = %w[main.beancount config/accounts.yaml config/prompts/default/spec.json
             config/prompts/classify/schema.json config/rules/.gitkeep accounts/.gitkeep .gitignore].freeze

  def test_creates_the_files_and_a_first_commit
    with_temp_dir do |tmp|
      dir = File.join(tmp, 'ledger')
      out, err, status = Open3.capture3(scrubbed_env, SCRIPT, dir)

      assert_predicate status, :success?, err
      FILES.each { |file| assert_path_exists File.join(dir, file) }
      assert_equal %w[alpaca classify default multi], Dir.children(File.join(dir, 'config', 'prompts')).sort
      assert_equal %w[accounts config main.beancount], Dir.children(dir).sort - ['.git', '.gitignore']
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

  # An existing ledger: a directory with its own main file and no git, no config.
  def test_adopts_an_existing_ledger_adding_only_what_is_missing
    with_temp_dir do |tmp|
      File.write(File.join(tmp, 'ledger.beancount'), "2020-01-01 open Assets:Banco\n")
      out, err, status = Open3.capture3(scrubbed_env, SCRIPT, tmp)

      assert_predicate status, :success?, err
      assert_path_exists File.join(tmp, 'config', 'accounts.yaml')
      assert_path_exists File.join(tmp, 'config', 'prompts', 'default', 'spec.json')
      refute_path_exists File.join(tmp, 'main.beancount'), 'the ledger has its own main file'
      assert_equal "2020-01-01 open Assets:Banco\n", File.read(File.join(tmp, 'ledger.beancount'))
      log, = Open3.capture2(scrubbed_env, 'git', '-C', tmp, 'log', '--oneline')
      assert_equal 1, log.lines.size, 'git init and one commit'
      assert_includes out, 'LEDGER_MAIN_FILE=ledger.beancount'
    end
  end

  def test_adopting_keeps_the_existing_files_and_commits_on_top
    with_temp_dir do |tmp|
      spec = File.join(tmp, 'config', 'prompts', 'default', 'spec.json')
      FileUtils.mkdir_p(File.dirname(spec))
      File.write(spec, '{"model": "mine"}')
      Open3.capture3(scrubbed_env, 'git', '-C', tmp, 'init', '-q')
      Open3.capture3(scrubbed_env, 'git', '-C', tmp, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit',
                     '-q', '--allow-empty', '-m', 'viejo')

      _out, err, status = Open3.capture3(scrubbed_env, SCRIPT, tmp)

      assert_predicate status, :success?, err
      assert_equal '{"model": "mine"}', File.read(spec)
      assert_path_exists File.join(tmp, 'config', 'prompts', 'classify', 'spec.json')
      log, = Open3.capture2(scrubbed_env, 'git', '-C', tmp, 'log', '--oneline')
      assert_equal 2, log.lines.size
      assert_match(/Frijolero/, log.lines.first)
    end
  end

  def test_adopting_twice_changes_nothing
    with_temp_dir do |tmp|
      Open3.capture3(scrubbed_env, SCRIPT, tmp)
      out, err, status = Open3.capture3(scrubbed_env, SCRIPT, tmp)

      assert_predicate status, :success?, err
      assert_includes out, 'nada que agregar'
      log, = Open3.capture2(scrubbed_env, 'git', '-C', tmp, 'log', '--oneline')
      assert_equal 1, log.lines.size
    end
  end

  private

  # A git hook exports GIT_DIR and friends. Scrubbed, or the script commits to this repo.
  def scrubbed_env
    ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
  end
end
