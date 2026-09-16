# frozen_string_literal: true

module Frijolero
  # Every account the ledger opens or a rule names, for the list beside the rules editor.
  module LedgerAccounts
    OPEN = /^\d{4}-\d{2}-\d{2} open (\S+)/
    RULE = /account:\s*['"]?([A-Z][\w:-]+)/

    def self.all
      text = files.uniq.select { |f| File.exist?(f) }.map { |f| File.read(f) }.join("\n")
      (text.scan(OPEN) + text.scan(RULE)).flatten.uniq.sort
    end

    def self.files = [Config.main_file, Config.account_opens_file, *Dir.glob(File.join(Config.rules_dir, '*.yaml'))]
  end
end
