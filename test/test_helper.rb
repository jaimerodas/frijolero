# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "frijolero"
require "minitest/autorun"
require "fileutils"
require "tmpdir"

module TestHelpers
  FIXTURES_DIR = File.expand_path("fixtures", __dir__)

  def fixture_path(name)
    File.join(FIXTURES_DIR, name)
  end

  def with_temp_dir
    Dir.mktmpdir do |dir|
      yield dir
    end
  end

  def with_temp_config_dir
    Dir.mktmpdir do |dir|
      old_config_dir = Frijolero::Config::CONFIG_DIR

      # Temporarily override config directory
      Frijolero::Config.send(:remove_const, :CONFIG_DIR)
      Frijolero::Config.const_set(:CONFIG_DIR, dir)
      Frijolero::Config.send(:remove_const, :CONFIG_FILE)
      Frijolero::Config.const_set(:CONFIG_FILE, File.join(dir, "config.yaml"))
      Frijolero::Config.send(:remove_const, :ACCOUNTS_FILE)
      Frijolero::Config.const_set(:ACCOUNTS_FILE, File.join(dir, "accounts.yaml"))
      Frijolero::Config.send(:remove_const, :DETAILERS_DIR)
      Frijolero::Config.const_set(:DETAILERS_DIR, File.join(dir, "detailers"))

      Frijolero::Config.reload!

      yield dir
    ensure
      # Restore original constants
      Frijolero::Config.send(:remove_const, :CONFIG_DIR)
      Frijolero::Config.const_set(:CONFIG_DIR, old_config_dir)
      Frijolero::Config.send(:remove_const, :CONFIG_FILE)
      Frijolero::Config.const_set(:CONFIG_FILE, File.join(old_config_dir, "config.yaml"))
      Frijolero::Config.send(:remove_const, :ACCOUNTS_FILE)
      Frijolero::Config.const_set(:ACCOUNTS_FILE, File.join(old_config_dir, "accounts.yaml"))
      Frijolero::Config.send(:remove_const, :DETAILERS_DIR)
      Frijolero::Config.const_set(:DETAILERS_DIR, File.join(old_config_dir, "detailers"))

      Frijolero::Config.reload!
    end
  end
end
