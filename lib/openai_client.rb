# frozen_string_literal: true

require 'json'

module Frijolero
  # The Responses API in background mode with a 2 s poll, because an extraction can
  # take minutes. The PDF goes inline as base64 (the API takes up to 50 MB).
  class OpenAIClient
    BASE_URL = 'https://api.openai.com/v1'
    POLL_INTERVAL_SECONDS = 2
    # A response still queued after this long is stuck. On 2026-10-26, four of eight
    # background requests stayed queued for 10 to 15 minutes, and the same requests,
    # sent again, finished in 5 to 38 s.
    QUEUE_LIMIT_SECONDS = 60

    def initialize(api_key, transport: nil, poll_interval: POLL_INTERVAL_SECONDS, poll_timeout: nil,
                   queue_limit: QUEUE_LIMIT_SECONDS)
      @transport = transport || LLM::Transport.new(base_url: BASE_URL,
                                                   headers: { 'Authorization' => "Bearer #{api_key}" })
      @poll_interval = poll_interval
      @poll_timeout = poll_timeout || Config.llm_timeout
      @queue_limit = queue_limit
    end

    # A response stuck in the queue goes once more; a second one stuck is an APIError,
    # which LLM.report treats as recoverable, so the job can be retried.
    def extract(pdf_path, spec)
      body = request_body(spec, pdf_path)
      data = poll_response(create(body))
      data ||= poll_response(create(body))
      raise LLM::APIError, "OpenAI left the response queued for #{@queue_limit}s, twice" unless data

      record_usage(spec, data)
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

    # Before the text is parsed: the call is paid even if the parsing fails.
    def record_usage(spec, data)
      usage = data['usage']
      Log.puts 'Warning: the response has no usage; recording zeros' unless usage
      usage ||= {}
      Usage.record(prompt: spec['_prompt'], model: spec['model'], input_tokens: usage['input_tokens'] || 0,
                   cached_tokens: usage.dig('input_tokens_details', 'cached_tokens') || 0,
                   output_tokens: usage['output_tokens'] || 0)
    end

    def response_text(data)
      message = data['output']&.find { |o| o['type'] == 'message' }
      message&.fetch('content', nil)&.find { |c| c['type'] == 'output_text' }&.fetch('text', nil)
    end

    def create(body) = @transport.post_json('/responses', body)['id']

    # It may have finished in between, and then there is nothing to cancel.
    def cancel(response_id)
      @transport.post_json("/responses/#{response_id}/cancel", {})
    rescue LLM::Error
      nil
    end

    # The completed response, or nil when it stayed queued past the queue limit.
    def poll_response(response_id)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      loop do
        sleep @poll_interval
        data = @transport.get("/responses/#{response_id}")

        case data['status']
        when 'completed'
          return data
        when 'queued', 'in_progress'
          return unless waiting?(response_id, data['status'], Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
        else
          raise LLM::APIError, "Response failed with status: #{data['status']}"
        end
      end
    end

    # True while the response can still finish. False when it stayed queued past the
    # queue limit, and an APIError past the timeout. A response given up on is cancelled
    # first, so it never runs and bills later.
    def waiting?(response_id, status, elapsed)
      stuck = status == 'queued' && elapsed >= @queue_limit
      return true unless stuck || elapsed >= @poll_timeout

      cancel(response_id)
      raise LLM::APIError, "Response polling timed out after #{@poll_timeout}s (still #{status})" unless stuck

      Log.puts "OpenAI left the response queued for #{@queue_limit}s: sending it again"
      false
    end
  end
end
