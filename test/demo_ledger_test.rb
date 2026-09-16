# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'

class DemoLedgerTest < Minitest::Test
  include TestHelpers

  SCRIPT = File.expand_path('../bin/demo-ledger', __dir__)

  def test_builds_a_ledger_the_app_can_serve
    skip 'rledger not installed' unless rledger?

    with_temp_dir do |tmp|
      dir = File.join(tmp, 'demo')
      out, err, status = Open3.capture3(scrubbed_env, SCRIPT, dir, '--months', '3', '--seed', '7')

      assert_predicate status, :success?, err
      assert_includes out, 'semilla 7'
      assert_includes out, 'LEDGER_DIR='
      ledger = File.join(dir, 'ledger')
      periods = (1..3).map { |i| Date.today.prev_month(i).strftime('%y%m') }
      ['Zeus', 'Hera TDC', 'Atenea'].each do |key|
        periods.each do |period|
          assert_path_exists File.join(ledger, 'accounts', key, "#{key} #{period}.beancount")
          assert_path_exists File.join(dir, 'pdfs', 'frijolero', 'accounts', key, "#{key} #{period}.pdf")
        end
        assert_path_exists File.join(ledger, 'config', 'rules', "#{key}.yaml")
      end
      assert_equal 3, YAML.load_file(File.join(ledger, 'config', 'accounts.yaml')).size
      assert_includes File.read(File.join(ledger, 'accounts', 'Hera TDC', "Hera TDC #{periods.first}.beancount")),
                      'Expenses:FIXME'
      jobs = File.readlines(File.join(dir, 'jobs.jsonl')).map { JSON.parse(it) }
      assert_equal 10, jobs.size
      assert_equal %w[failed], jobs.map { it['status'] }.grep('failed')
      log, = Open3.capture2(scrubbed_env, 'git', '-C', ledger, 'log', '--oneline')
      assert_equal 2, log.lines.size
      _, _, check = Open3.capture3('rledger', 'check', '--no-cache', File.join(ledger, 'main.beancount'))
      assert_predicate check, :success?
    end
  end

  def test_picks_a_seed_and_prints_it
    skip 'rledger not installed' unless rledger?

    with_temp_dir do |tmp|
      out, err, status = Open3.capture3(scrubbed_env, SCRIPT, File.join(tmp, 'demo'), '--months', '1')

      assert_predicate status, :success?, err
      assert_match(/semilla \d+\./, out)
    end
  end

  def test_contractor_gets_invoices_and_taxes
    skip 'rledger not installed' unless rledger?

    with_temp_dir do |tmp|
      dir = File.join(tmp, 'demo')
      _, err, status = Open3.capture3(scrubbed_env, SCRIPT, dir, '--months', '2', '--persona', 'contractor')

      assert_predicate status, :success?, err
      zeus = Dir[File.join(dir, 'ledger', 'accounts', 'Zeus', '*.beancount')].map { File.read(it) }.join
      assert_includes zeus, 'Income:Honorarios'
      assert_includes zeus, 'Expenses:Impuestos'
      refute_includes zeus, 'Income:Sueldo'
    end
  end

  private

  def rledger? = system('rledger', '--version', out: File::NULL, err: File::NULL)

  def scrubbed_env
    ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
  end
end
