# frozen_string_literal: true

# Sinatra fixes its environment (and with it host authorization) the first time
# sinatra/base loads, so this must come before the app.
ENV['RACK_ENV'] = 'test'

require_relative '../app/app'
require 'minitest/autorun'
require 'minitest/mock'
require 'fileutils'
require 'tmpdir'
module TestHelpers
  FIXTURES_DIR = File.expand_path('fixtures', __dir__)
  TEMPLATES_DIR = File.expand_path('../templates', __dir__)

  def fixture_path(name)
    File.join(FIXTURES_DIR, name)
  end

  def template_path(name)
    File.join(TEMPLATES_DIR, name)
  end

  def with_temp_dir(&)
    Dir.mktmpdir(&)
  end

  # Points LEDGER_DIR at a fresh temp dir with config/ inside; restores ENV after.
  def with_ledger_dir
    Dir.mktmpdir do |dir|
      old = ENV.to_h.slice('LEDGER_DIR', 'LEDGER_MAIN_FILE')
      ENV['LEDGER_DIR'] = dir
      ENV.delete('LEDGER_MAIN_FILE')
      FileUtils.mkdir_p(File.join(dir, 'config'))
      yield dir
    ensure
      ENV.delete('LEDGER_DIR')
      ENV.delete('LEDGER_MAIN_FILE')
      ENV.merge!(old)
    end
  end
end
