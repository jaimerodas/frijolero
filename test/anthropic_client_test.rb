# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

class AnthropicClientTest < Minitest::Test
  include TestHelpers

  class FakeTransport
    attr_reader :calls

    def initialize(response)
      @response = response
      @calls = []
    end

    def post_json(path, body)
      @calls << [path, body]
      @response
    end
  end

  DONE = { 'stop_reason' => 'end_turn', 'content' => [{ 'type' => 'text', 'text' => '{"transactions":[]}' }] }.freeze
  SPEC = { '_comment' => 'note', 'model' => 'claude-test', 'instructions' => 'Extract the transactions.',
           'format' => { 'type' => 'json_schema', 'name' => 'transactions', 'strict' => true,
                         'schema' => { 'type' => 'object', 'additionalProperties' => false } } }.freeze

  def extract(response, spec = SPEC)
    transport = FakeTransport.new(response)
    Tempfile.create(['statement', '.pdf']) do |f|
      f.write('%PDF-1.4')
      f.flush
      result = Frijolero::AnthropicClient.new('k', transport: transport).extract(f.path, spec)
      [result, transport.calls.first]
    end
  end

  def test_extract_builds_a_messages_request_with_the_pdf_inline_and_the_schema
    result, (path, body) = extract(DONE)

    assert_equal({ 'transactions' => [] }, result)
    assert_equal '/messages', path
    assert_equal 'claude-test', body['model']
    assert_equal 'Extract the transactions.', body['system']
    assert_equal 16_000, body['max_tokens']
    assert_equal({ 'type' => 'json_schema', 'schema' => SPEC['format']['schema'] }, body['output_config']['format'])
    refute body.key?('format')
    refute body.key?('instructions')
    refute body.key?('_comment')
    doc = body['messages'].first[:content].first
    assert_equal 'document', doc[:type]
    assert_equal({ type: 'base64', media_type: 'application/pdf', data: Base64.strict_encode64('%PDF-1.4') },
                 doc[:source])
  end

  # Anything else in spec.json goes to the API as-is, and output_config keeps its keys.
  def test_extra_spec_keys_pass_through
    spec = SPEC.merge('max_tokens' => 4000, 'thinking' => { 'type' => 'adaptive' },
                      'output_config' => { 'effort' => 'low' })

    _, (_, body) = extract(DONE, spec)

    assert_equal 4000, body['max_tokens']
    assert_equal({ 'type' => 'adaptive' }, body['thinking'])
    assert_equal 'low', body['output_config']['effort']
    assert_equal 'json_schema', body['output_config']['format']['type']
  end

  def test_extract_does_not_mutate_the_spec
    spec = Marshal.load(Marshal.dump(SPEC))

    extract(DONE, spec)

    assert_equal SPEC, spec
  end

  def test_a_truncated_answer_raises_instead_of_parsing_half_a_json
    response = { 'stop_reason' => 'max_tokens', 'content' => [{ 'type' => 'text', 'text' => '{"transactions":[' }] }

    error = assert_raises(Frijolero::LLM::APIError) { extract(response) }

    assert_includes error.message, 'max_tokens'
  end

  def test_a_refusal_raises_with_its_details
    response = { 'stop_reason' => 'refusal', 'stop_details' => { 'category' => 'x' }, 'content' => [] }

    error = assert_raises(Frijolero::LLM::APIError) { extract(response) }

    assert_includes error.message, 'refusal'
    assert_includes error.message, 'category'
  end

  def test_extract_raises_when_the_answer_has_no_text
    error = assert_raises(Frijolero::LLM::APIError) { extract({ 'stop_reason' => 'end_turn', 'content' => [] }) }

    assert_includes error.message, 'Failed to extract'
  end
end
