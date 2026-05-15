# frozen_string_literal: true

require 'json'

module Frijolero
  module Converters
    class Base
      def self.convert(**kwargs)
        new(**kwargs).convert
      end

      def initialize(input:, account:, output: nil)
        raise ArgumentError, 'input file required' unless input
        raise ArgumentError, 'account required' unless account

        @input = input
        @account = account
        @output = output
      end

      def convert
        out_path = @output || derived_output_path
        File.open(out_path, 'w') { |io| run_to(io) }
        out_path
      end

      def run_to(_io)
        raise NotImplementedError, "#{self.class} must implement #run_to(io)"
      end

      private

      def derived_output_path
        File.expand_path(File.join(File.dirname(@input), '..',
                                   "#{File.basename(@input, '.json')}.beancount"))
      end

      def load_json
        JSON.parse(File.read(@input, encoding: 'UTF-8'))
      end
    end
  end
end
