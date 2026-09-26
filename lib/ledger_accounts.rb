# frozen_string_literal: true

module Frijolero
  # Every account the ledger opens or a rule names, for the list beside the rules editor,
  # and the ones a posting can use, for the autocomplete.
  module LedgerAccounts
    OPEN = /^\d{4}-\d{2}-\d{2} open (\S+)/
    CLOSE = /^\d{4}-\d{2}-\d{2} close (\S+)/
    RULE = /account:\s*['"]?([A-Z][\w:-]+)/

    def self.all
      (text.scan(OPEN) + text.scan(RULE)).flatten.uniq.sort
    end

    # Opened and not closed: a name only a rule uses, or a closed account, would fail the
    # ledger check. ponytail: an account closed and opened again counts as closed.
    def self.active
      (text.scan(OPEN) - text.scan(CLOSE)).flatten.uniq.sort
    end

    def self.text
      files.uniq.select { |f| File.exist?(f) }.map { |f| File.read(f) }.join("\n")
    end

    INCLUDE = /^include "(.+)"/

    # The main file, what it includes (one level: enough for an adopted ledger that keeps its
    # opens in a file of its own), the opens file and the rules.
    def self.files
      [Config.main_file, *included, Config.account_opens_file, *Dir.glob(File.join(Config.rules_dir, '*.yaml'))]
    end

    def self.included
      return [] unless File.exist?(Config.main_file)

      dir = File.dirname(Config.main_file)
      File.read(Config.main_file).scan(INCLUDE).flatten.flat_map { |pattern| Dir.glob(File.expand_path(pattern, dir)) }
    end
  end
end
