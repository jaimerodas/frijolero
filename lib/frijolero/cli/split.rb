# frozen_string_literal: true

require 'optparse'

module Frijolero
  class CLI
    class Split
      include Helpers

      def self.call(args)
        new(args).call
      end

      def initialize(args)
        @args = args
        @options = { dry_run: false }
      end

      def call
        parse_options
        check_config!
        beancount_file = ensure_beancount_file!

        splitter = TransactionSplitter.new(beancount_file: beancount_file)
        summary = splitter.summary
        return UI.puts('No inline transactions found.') if summary.empty?

        show_summary(summary)
        account_key = @args.first || ask_account_key(summary)
        return unless account_key

        run_split(splitter, account_key)
      end

      private

      def parse_options
        OptionParser.new do |opts|
          opts.banner = 'Usage: frijolero split [ACCOUNT] [--dry-run]'

          opts.on('--dry-run', 'Show what would be done without modifying files') do
            @options[:dry_run] = true
          end

          help_option(opts)
        end.parse!(@args)
      end

      def ensure_beancount_file!
        beancount_file = Config.beancount_main_file
        return beancount_file if beancount_file && File.exist?(beancount_file)

        warn 'Beancount file not found. Set paths.beancount_main in ~/.frijolero/config.yaml'
        exit 1
      end

      def show_summary(summary)
        total = summary.values.sum
        UI.frame("Summary: #{total} inline transactions") do
          summary.each { |account, count| UI.puts "  #{account}: #{count}" }
        end
      end

      def ask_account_key(summary)
        choosable = summary.keys.reject { |k| k == 'Other' }
        return UI.puts('No configured accounts to split.') if choosable.empty?

        UI.ask_select('Which account do you want to split?', choosable)
      end

      def run_split(splitter, account_key)
        UI.frame("Splitting: #{account_key}") do
          result = splitter.split(account_key: account_key, dry_run: @options[:dry_run])
          report_result(result, account_key)
        end
      end

      def report_result(result, account_key)
        return UI.puts("No transactions found for #{account_key}") if result[:matched].zero?

        result[:groups].sort.each do |yymm, count|
          skip = result[:existing]&.include?(yymm) ? ' {{x}} already exists' : ''
          UI.puts "  #{result[:prefix]}_#{yymm}.beancount: #{count} transactions#{skip}"
        end

        UI.puts ''
        UI.puts(@options[:dry_run] ? '(dry run — no files modified)' : success_message(result))
      end

      def success_message(result)
        "{{v}} #{result[:extracted]} transactions extracted into #{result[:files]} files"
      end
    end
  end
end
