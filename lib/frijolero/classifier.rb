# frozen_string_literal: true

require 'date'

module Frijolero
  # Decides which account a statement PDF belongs to and which period it covers.
  class Classifier
    UNKNOWN = 'unknown'
    Result = Struct.new(:account, :period, :period_start, :period_end, :file_id, keyword_init: true) do
      def unknown? = account == UNKNOWN
    end

    def initialize(client:, today: Date.today)
      @client = client
      @today = today
    end

    def classify(pdf_path)
      filename_result(pdf_path) || classify_via_openai(pdf_path)
    end

    private

    # A parseable, known filename ("AMEX 2508.pdf") answers without any OpenAI call.
    def filename_result(pdf_path)
      key, period = AccountConfig.parse_filename(pdf_path)
      return nil unless key && AccountConfig.find_config(key)

      Result.new(account: key, period: period, file_id: nil)
    end

    def classify_via_openai(pdf_path)
      file_id = @client.upload_file(pdf_path)
      data = @client.extract_transactions(file_id, request_spec)
      account, period = validate(data)
      Result.new(account: account, period: period, period_start: data['period_start'],
                 period_end: data['period_end'], file_id: file_id)
    end

    # Deep-copies the loaded template (Marshal round trip) so it is not mutated, then fills
    # the account enum and the instructions' account list from accounts.yaml.
    def request_spec
      spec = Marshal.load(Marshal.dump(Config.openai_prompt_spec('classify')))
      descriptions = AccountConfig.descriptions
      spec['format']['schema']['properties']['account']['enum'] = descriptions.keys + [UNKNOWN]
      spec['instructions'] += "#{descriptions.map { |key, desc| "- #{key}: #{desc}" }.join("\n")}\n"
      spec
    end

    def validate(data)
      account = data['account']
      account = UNKNOWN unless AccountConfig.descriptions.key?(account)
      start, finish = dates(data)
      return [UNKNOWN, nil] unless plausible?(start, finish)

      [account, period(start, finish)]
    end

    def dates(data)
      [Date.iso8601(data['period_start']), Date.iso8601(data['period_end'])]
    rescue ArgumentError, TypeError
      nil
    end

    def plausible?(start, finish)
      start && finish > start && finish <= @today && finish >= (@today << 24)
    end

    # The month that holds most of the statement's days, so an AMEX cycle of Aug 4
    # to Sep 3 is 2608. The midpoint lands in that month; a tie goes to the start.
    def period(start, finish)
      (start + ((finish - start) / 2).floor).strftime('%y%m')
    end
  end
end
