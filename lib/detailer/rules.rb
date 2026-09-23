# frozen_string_literal: true

require 'bigdecimal'
require 'yaml'

module Frijolero
  class Detailer
    # Pure matching engine for detailer YAML. Knows nothing about where a
    # transaction came from, so both the JSON detailer and the beancount
    # detailer can share it.
    class Rules
      MATCHERS = {
        'start_with' => ->(pattern, description) { description.start_with?(pattern) },
        'include' => ->(pattern, description) { description.include?(pattern) }
      }.freeze

      def self.load(config_path)
        new(YAML.load_file(config_path))
      end

      # The fields a list of matches sets, a later rule overwriting what it sets.
      def self.merge(matched)
        matched.reduce({}) { |fields, rule| fields.merge(rule.slice('payee', 'narration', 'account').compact) }
      end

      def initialize(config)
        @config = config || {}
      end

      # Every rule that applies, in the order their fields should be merged:
      # all `start_with` patterns in YAML order, then all `include` patterns.
      # A later rule overwrites the fields it sets and leaves the rest alone.
      # Whitespace is collapsed to single spaces first, the same as
      # Converters::Default does when it writes the narration, so a rule reads
      # the same against the JSON (where a model may keep the PDF's line breaks)
      # and against the .beancount file.
      def matches_for(description:, amount:)
        return [] unless description

        description = description.gsub(/\s+/, ' ').strip
        MATCHERS.flat_map do |section, matcher|
          winning_rules(@config[section], description, amount, &matcher)
        end
      end

      private

      def winning_rules(patterns, description, amount, &matcher)
        return [] unless patterns

        patterns.filter_map do |pattern, rules|
          next unless matcher.call(pattern, description)

          normalize(rules).find { |entry| conditions_met?(entry['when'], amount) }
        end
      end

      def normalize(rules)
        case rules
        when Array then rules.grep(Hash)
        when Hash then [rules]
        else []
        end
      end

      def conditions_met?(conditions, amount)
        return true unless conditions

        conditions.all? do |field, expected|
          case field
          when 'amount' then same_amount?(amount, expected)
          else false
          end
        end
      end

      def same_amount?(actual, expected)
        actual = decimal(actual)
        !actual.nil? && actual == decimal(expected)
      end

      def decimal(value)
        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
