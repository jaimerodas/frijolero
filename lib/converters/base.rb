# frozen_string_literal: true

require 'json'

module Frijolero
  module Converters
    class Base
      # Built before the file opens, so a missing account never truncates the output.
      def self.convert(output:, **)
        converter = new(**)
        File.open(output, 'w') { |io| converter.run_to(io) }
      end

      # accounts.yaml is edited by hand: a block without beancount_account must not
      # become postings with no account.
      def initialize(input:, account:)
        raise ArgumentError, 'account required' unless account

        @input = input
        @account = account
      end

      private

      def load_json
        JSON.parse(File.read(@input, encoding: 'UTF-8'))
      end
    end
  end
end
