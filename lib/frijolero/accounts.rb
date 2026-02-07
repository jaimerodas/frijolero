# frozen_string_literal: true

module Frijolero
  class Accounts
    OPEN_DIRECTIVE_REGEX = /^\d{4}-\d{2}-\d{2}\s+open\s+((?:Assets|Liabilities|Income|Expenses|Equity)(?::\S+)+)/

    def initialize(file: nil)
      file ||= Config.beancount_accounts_file
      raise ArgumentError, "No accounts file specified. Set paths.beancount_accounts in ~/.frijolero/config.yaml" unless file
      raise ArgumentError, "File not found: #{file}" unless File.exist?(file)

      @accounts = parse(file)
    end

    def all
      @accounts
    end

    def search(query)
      return @accounts if query.nil? || query.strip.empty?

      pattern = query.downcase
      @accounts.select { |account| account.downcase.include?(pattern) }
    end

    private

    def parse(file)
      accounts = []
      File.foreach(file) do |line|
        match = line.match(OPEN_DIRECTIVE_REGEX)
        accounts << match[1] if match
      end
      accounts.uniq.sort
    end
  end
end
