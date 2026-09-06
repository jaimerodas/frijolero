# frozen_string_literal: true

require 'date'
require 'yaml'

module Frijolero
  # The two edits one new Default-pipeline account needs in the ledger: a block at
  # the end of accounts.yaml and an `open` line in account_opens.beancount.
  module NewAccount
    class Invalid < StandardError; end

    BEANCOUNT_ACCOUNT = /\A(Assets|Liabilities|Equity|Income|Expenses)(:[A-Z][A-Za-z0-9-]*)+\z/
    FIELDS = %w[key description beancount_account openai_prompt_type cutoff_day opened_on].freeze

    class << self
      # The prompt directories in the ledger, minus the classifier's.
      def prompt_types
        Dir.children(Config.prompts_dir).sort - ['classify']
      end

      # [key, entry, opened_on] from the form, or Invalid with the message for the form.
      def parse!(values)
        key = values['key']
        raise Invalid, 'Falta la clave' if key.empty?
        raise Invalid, "#{key} ya existe" if Config.accounts.key?(key)
        raise Invalid, 'La clave no puede terminar en cuatro dígitos' if key.match?(/ \d{4}\z/)

        [key, entry(values), opened_on(values['opened_on'])]
      end

      # `text` with the block appended. Every existing byte, comments included, stays.
      def append_block(text, key, entry)
        text = "#{text}\n" unless text.empty? || text.end_with?("\n")
        text + YAML.dump({ key => entry }).delete_prefix("---\n")
      end

      # Appends `date open account` unless the file already opens that account.
      def add_open_line(path, date, account)
        text = File.exist?(path) ? File.read(path) : ''
        return if text.match?(/^\d{4}-\d{2}-\d{2} open #{Regexp.escape(account)}\s*$/)

        text = "#{text}\n" unless text.empty? || text.end_with?("\n")
        File.write(path, "#{text}#{date.iso8601} open #{account}\n")
      end

      private

      def entry(values)
        raise Invalid, 'Cuenta Beancount inválida' unless values['beancount_account'].match?(BEANCOUNT_ACCOUNT)
        raise Invalid, 'Tipo de prompt desconocido' unless prompt_types.include?(values['openai_prompt_type'])

        entry = values.slice('beancount_account', 'openai_prompt_type', 'description').reject { |_, v| v.empty? }
        entry['cutoff_day'] = cutoff_day(values['cutoff_day']) unless values['cutoff_day'].empty?
        entry
      end

      def cutoff_day(text)
        day = Integer(text, exception: false)
        raise Invalid, 'El día de corte va de 1 a 31' unless day&.between?(1, 31)

        day
      end

      def opened_on(text)
        Date.iso8601(text)
      rescue Date::Error
        raise Invalid, 'Fecha de apertura inválida'
      end
    end
  end
end
