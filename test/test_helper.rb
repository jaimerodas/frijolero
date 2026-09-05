# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'frijolero'
require 'minitest/autorun'
require 'minitest/mock'
require 'fileutils'
require 'tmpdir'

module TestHelpers
  FIXTURES_DIR = File.expand_path('fixtures', __dir__)

  def fixture_path(name)
    File.join(FIXTURES_DIR, name)
  end

  def with_temp_dir(&block)
    Dir.mktmpdir(&block)
  end

  # Points LEDGER_DIR at a fresh temp dir with config/ inside; restores ENV after.
  def with_ledger_dir
    Dir.mktmpdir do |dir|
      old = ENV.to_h.slice('LEDGER_DIR', 'LEDGER_MAIN_FILE')
      ENV['LEDGER_DIR'] = dir
      ENV.delete('LEDGER_MAIN_FILE')
      FileUtils.mkdir_p(File.join(dir, 'config'))
      Frijolero::Config.reload!
      yield dir
    ensure
      ENV.delete('LEDGER_DIR')
      ENV.delete('LEDGER_MAIN_FILE')
      ENV.merge!(old)
      Frijolero::Config.reload!
    end
  end
end
