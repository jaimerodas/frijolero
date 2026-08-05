# frozen_string_literal: true

require 'optparse'
require 'json'

module Frijolero
  class CLI
    class Detail
      include Helpers

      def self.call(args)
        new(args).call
      end

      def initialize(args)
        @args = args
        @options = {}
      end

      def call
        parser = parse_options
        require_input!(@args.first, parser)

        file = @args.first
        require_existing!(file)
        config, auto_detected = resolve_config(file)

        if beancount?(file)
          run_beancount_detailer(file, config, auto_detected: auto_detected)
        else
          run_detailer(file, config, auto_detected: auto_detected)
        end
      end

      private

      def parse_options
        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: frijolero detail FILE[.json|.beancount] [-c CONFIG.yaml] [--dry-run]'

          opts.on('-c', '--config CONFIG', 'Config YAML file (auto-detected from filename if omitted)') do |v|
            @options[:config] = v
          end

          opts.on('--dry-run', 'Report what would change without writing (.beancount only)') do
            @options[:dry_run] = true
          end

          help_option(opts)
        end
        parser.parse!(@args)
        parser
      end

      def beancount?(file)
        File.extname(file).casecmp('.beancount').zero?
      end

      def require_existing!(file)
        return if File.exist?(file)

        UI.puts "{{x}} File not found: #{file}"
        exit 1
      end

      def resolve_config(file)
        return [@options[:config], false] if @options[:config]

        config = AccountConfig.detailer_config_for_file(file)
        report_account_lookup_failure(file, 'config', '-c') unless config

        [config, true]
      end

      def run_detailer(file, config, auto_detected:)
        UI.frame("Detailing: #{File.basename(file)}") do
          UI.puts "Config: #{UI.short_path(config)}" if auto_detected

          transactions = JSON.load_file(file)['transactions'] || []
          UI.puts "Found #{transactions.size} transactions#{UI.transaction_summary(transactions)}"

          UI.detailer_stats(Detailer.new(file, config).run)
        end
      end

      def run_beancount_detailer(file, config, auto_detected:)
        UI.frame("Detailing: #{File.basename(file)}") do
          UI.puts "Config: #{UI.short_path(config)}" if auto_detected

          detailer = BeancountDetailer.new(file, config)
          report_beancount_stats(detailer.run(dry_run: @options[:dry_run]), detailer.expense_account)
        end
      end

      def report_beancount_stats(stats, expense_account)
        UI.puts "#{stats[:total]} transactions, #{pending_count(stats)} on #{expense_account}"
        UI.detailer_stats(stats)
        UI.puts "{{!}} #{stats[:skipped].size} skipped (ambiguous or unparseable)" if stats[:skipped].any?
        UI.puts '{{i}} Dry run: nothing written' if @options[:dry_run]
      end

      # Skipped transactions are still on the FIXME account — they belong in the
      # count of what needs attention, not silently dropped from it.
      def pending_count(stats)
        stats[:detailed].size + stats[:remaining].size + stats[:skipped].size
      end
    end
  end
end
