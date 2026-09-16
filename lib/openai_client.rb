# frozen_string_literal: true

require 'json'

module Frijolero
  # The Responses API in background mode with a 2 s poll, because an extraction can
  # take minutes. The PDF goes inline as base64 (the API takes up to 50 MB).
  class OpenAIClient
    BASE_URL = 'https://api.openai.com/v1'
    POLL_INTERVAL_SECONDS = 2

    def initialize(api_key, transport: nil, poll_interval: POLL_INTERVAL_SECONDS, poll_timeout: nil)
      @transport = transport || LLM::Transport.new(base_url: BASE_URL,
                                                   headers: { 'Authorization' => "Bearer #{api_key}" })
      @poll_interval = poll_interval
      @poll_timeout = poll_timeout || Config.llm_timeout
    end

    def extract(pdf_path, spec)
      data = poll_response(@transport.post_json('/responses', request_body(spec, pdf_path))['id'])
      text = response_text(data)
      raise LLM::APIError, "Failed to extract transactions: #{data}" unless text

      JSON.parse(text)
    end

    private

    # The spec already mirrors the request body (model, instructions, reasoning and
    # anything else set in spec.json), so it goes as-is: only `format` moves under
    # `text.format`, and the PDF and `background` are added. Keys prefixed with `_`
    # (e.g. `_comment`) are documentation and are dropped.
    def request_body(spec, pdf_path)
      body = spec.reject { |key, _| key.to_s.start_with?('_') }
      body['text'] = { 'format' => body.delete('format') }
      body['input'] = [{ role: 'user', content: [input_file(pdf_path)] }]
      body['background'] = true
      body
    end

    def input_file(pdf_path)
      { type: 'input_file', filename: File.basename(pdf_path),
        file_data: "data:application/pdf;base64,#{LLM.pdf_base64(pdf_path)}" }
    end

    def response_text(data)
      message = data['output']&.find { |o| o['type'] == 'message' }
      message&.fetch('content', nil)&.find { |c| c['type'] == 'output_text' }&.fetch('text', nil)
    end

    def poll_response(response_id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @poll_timeout

      loop do
        sleep @poll_interval
        data = @transport.get("/responses/#{response_id}")

        case data['status']
        when 'completed'
          return data
        when 'queued', 'in_progress'
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise LLM::APIError, "Response polling timed out after #{@poll_timeout}s (still #{data['status']})"
          end

          next
        else
          raise LLM::APIError, "Response failed with status: #{data['status']}"
        end
      end
    end
  end
end
