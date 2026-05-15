# frozen_string_literal: true

require_relative 'cli/helpers'
require_relative 'cli/init'
require_relative 'cli/process'
require_relative 'cli/detail'
require_relative 'cli/convert'
require_relative 'cli/merge'
require_relative 'cli/csv'
require_relative 'cli/review'
require_relative 'cli/rename'
require_relative 'cli/split'
require_relative 'cli/migrate'

module Frijolero
  class CLI
    COMMANDS = {
      'init' => Init,
      'process' => Process,
      'detail' => Detail,
      'convert' => Convert,
      'merge' => Merge,
      'csv' => Csv,
      'review' => Review,
      'rename' => Rename,
      'split' => Split,
      'migrate' => Migrate
    }.freeze

    HELP_FLAGS = %w[--help -h].freeze
    VERSION_FLAGS = %w[--version -v].freeze

    def self.run(args = ARGV)
      new.run(args)
    end

    def run(args)
      Frijolero::UI.setup
      return show_help if args.empty? || HELP_FLAGS.include?(args.first)
      return puts("frijolero #{VERSION}") if VERSION_FLAGS.include?(args.first)

      dispatch(args.shift, args)
    end

    private

    def dispatch(name, args)
      command = COMMANDS[name]
      return command.call(args) if command

      warn "Unknown command: #{name}"
      warn "Run 'frijolero --help' for usage information"
      exit 1
    end

    def show_help
      puts <<~HELP
        Usage: frijolero COMMAND [OPTIONS]

        Commands:
          init               Create ~/.frijolero/ with example configs
          process            Process PDF statements end-to-end
          detail FILE.json   Enrich transactions with config rules
          convert FILE.json  Convert JSON to Beancount format
          merge FILE.bc      Merge beancount into main ledger
          csv FILE.json      Convert JSON to CSV
          review FILE.json   Review and edit transactions in web UI
          rename             Rename an account across all files
          split [ACCOUNT]    Split inline transactions into monthly files
          migrate            Migrate files from the legacy layout

        Options:
          --help, -h         Show this help message
          --version, -v      Show version

        Run 'frijolero COMMAND --help' for command-specific options.
      HELP
    end
  end
end
