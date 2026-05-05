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
        config, auto_detected = resolve_config(file)
        run_detailer(file, config, auto_detected: auto_detected)
      end

      private

      def parse_options
        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: frijolero detail FILE.json [-c CONFIG.yaml]'

          opts.on('-c', '--config CONFIG', 'Config YAML file (auto-detected from filename if omitted)') do |v|
            @options[:config] = v
          end

          help_option(opts)
        end
        parser.parse!(@args)
        parser
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
    end
  end
end
