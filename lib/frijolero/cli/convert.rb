# frozen_string_literal: true

require 'optparse'
require 'json'

module Frijolero
  class CLI
    class Convert
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

        input = @args.first
        @options[:input] = input
        @options[:account] ||= resolve_account(input)

        run_conversion(input)
      end

      private

      def parse_options
        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: frijolero convert FILE.json [-a ACCOUNT] [-o OUTPUT.beancount]'

          opts.on('-a', '--account ACCOUNT', 'Primary account (auto-detected from filename if omitted)') do |v|
            @options[:account] = v
          end

          opts.on('-o', '--output FILE', 'Output Beancount file') do |v|
            @options[:output] = v
          end

          opts.on('-e', '--expense ACCOUNT', 'Default expense account (default: Expenses:FIXME)') do |v|
            @options[:expense_account] = v
          end

          help_option(opts)
        end
        parser.parse!(@args)
        parser
      end

      def resolve_account(input)
        AccountConfig.beancount_account_for_file(input) ||
          report_account_lookup_failure(input, 'account', '-a')
      end

      def run_conversion(input)
        parsed = AccountConfig.parse_filename(input)
        account_config = parsed ? AccountConfig.find_config(parsed.first) : nil
        pipeline = Pipeline.for(account_config)
        data = JSON.load_file(input)

        UI.frame("Converting: #{File.basename(input)}") do
          UI.puts "Account: #{@options[:account]}"
          UI.puts pipeline.summary(data)

          output_path = pipeline.convert(
            json_path: input,
            output: @options[:output],
            account: @options[:account],
            expense_account: @options[:expense_account]
          )

          UI.puts "Saved: #{UI.short_path(output_path)}"
        end
      end
    end
  end
end
