# frozen_string_literal: true

require 'optparse'

module Frijolero
  class CLI
    class Csv
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

        CsvConverter.convert(input: @args.first, output: @options[:output])
      end

      private

      def parse_options
        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: frijolero csv FILE.json [-o OUTPUT.csv]'

          opts.on('-o', '--output FILE', 'Output CSV file') do |v|
            @options[:output] = v
          end

          help_option(opts)
        end
        parser.parse!(@args)
        parser
      end
    end
  end
end
