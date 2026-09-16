# frozen_string_literal: true

require 'json'

module Frijolero
  # The Messages API: one synchronous call with the PDF inline as base64 (the API
  # takes up to 32 MB) and the schema as a structured output. The read timeout is
  # the same budget as OpenAI's poll (LLM_TIMEOUT).
  class AnthropicClient
    BASE_URL = 'https://api.anthropic.com/v1'
    VERSION = '2023-06-01'
    # Room for a long statement; a spec.json can set its own max_tokens.
    MAX_TOKENS = 16_000

    def initialize(api_key, transport: nil)
      @transport = transport || LLM::Transport.new(base_url: BASE_URL, read_timeout: Config.llm_timeout,
                                                   headers: { 'x-api-key' => api_key, 'anthropic-version' => VERSION })
    end

    def extract(pdf_path, spec)
      data = @transport.post_json('/messages', request_body(spec, pdf_path))
      unless data['stop_reason'] == 'end_turn'
        raise LLM::APIError, "Response stopped early (#{data['stop_reason']}): #{data['stop_details'] || data['usage']}"
      end

      text = data['content']&.find { |c| c['type'] == 'text' }&.fetch('text', nil)
      raise LLM::APIError, "Failed to extract transactions: #{data}" unless text

      JSON.parse(text)
    end

    private

    # The same spec as OpenAI's: `instructions` is the system prompt, `format.schema`
    # the structured output, and any other key (max_tokens, thinking, output_config's
    # effort) goes as-is. Keys prefixed with `_` are documentation and are dropped.
    def request_body(spec, pdf_path)
      body = spec.reject { |key, _| key.to_s.start_with?('_') }
      body['system'] = body.delete('instructions')
      body['max_tokens'] ||= MAX_TOKENS
      format = { 'type' => 'json_schema', 'schema' => body.delete('format')['schema'] }
      body['output_config'] = (body['output_config'] || {}).merge('format' => format)
      body['messages'] = [{ role: 'user', content: [document(pdf_path)] }]
      body
    end

    def document(pdf_path)
      { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: LLM.pdf_base64(pdf_path) } }
    end
  end
end
