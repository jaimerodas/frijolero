# frozen_string_literal: true

module Frijolero
  # Puts a statement's file into the ledger: `include "<path>"` at the end of the
  # main file, relative to its directory, unless the main file already has it.
  module BeancountMerger
    def self.merge(file)
      main = File.expand_path(Config.main_file)
      relative = Pathname(File.expand_path(file)).relative_path_from(File.dirname(main)).to_s
      line = /^include\s+"#{Regexp.escape(relative)}"\s*$/
      return if File.exist?(main) && File.foreach(main).any? { |existing| existing.match?(line) }

      File.open(main, 'a') { |out| out.puts %(include "#{relative}") }
    end
  end
end
