# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

class OpenAIClientTest < Minitest::Test
  include TestHelpers

  class FakeTransport
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def post_json(path, body)
      @calls << [:post_json, path, body]
      @responses.fetch(:post_json)
    end

    def get(path)
      @calls << [:get, path]
      @responses.fetch(:get)
    end
  end

  COMPLETED = { 'status' => 'completed',
                'output' => [{ 'type' => 'message',
                               'content' => [{ 'type' => 'output_text', 'text' => '{"transactions":[]}' }] }] }.freeze

  def client(transport, **)
    Frijolero::OpenAIClient.new('test-key', transport: transport, poll_interval: 0, **)
  end

  def with_pdf
    Tempfile.create(['statement', '.pdf']) do |f|
      f.write('%PDF-1.4')
      f.flush
      yield f.path
    end
  end

  def test_extract_forwards_the_spec_with_the_pdf_inline_and_parses_the_answer
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: COMPLETED)
    format = { 'type' => 'json_schema', 'name' => 'transactions', 'strict' => true, 'schema' => { 'type' => 'object' } }
    spec = { '_comment' => 'a note for humans, not the API', 'model' => 'gpt-test',
             'instructions' => 'Extract the transactions.', 'format' => format,
             'reasoning' => { 'effort' => 'high', 'summary' => 'auto' } }

    result = with_pdf { |pdf| client(transport).extract(pdf, spec) }

    assert_equal({ 'transactions' => [] }, result)
    method, path, body = transport.calls.first
    assert_equal [:post_json, '/responses'], [method, path]
    refute body.key?('_comment'), 'comment keys must be stripped'
    refute body.key?('format'), 'format must move under text.format'
    assert_equal 'gpt-test', body['model']
    assert_equal 'Extract the transactions.', body['instructions']
    assert_equal({ 'effort' => 'high', 'summary' => 'auto' }, body['reasoning'])
    assert_equal format, body['text']['format']
    assert_equal true, body['background']
    file = body['input'].first[:content].first
    assert_equal 'input_file', file[:type]
    assert_equal "data:application/pdf;base64,#{Base64.strict_encode64('%PDF-1.4')}", file[:file_data]
    assert_equal [:get, '/responses/resp-1'], transport.calls.last
  end

  def test_extract_does_not_mutate_the_spec
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: COMPLETED)
    spec = { 'model' => 'gpt-test', 'format' => { 'type' => 'json_schema' } }

    with_pdf { |pdf| client(transport).extract(pdf, spec) }

    assert_equal({ 'model' => 'gpt-test', 'format' => { 'type' => 'json_schema' } }, spec)
  end

  def test_extract_raises_when_the_response_has_no_text
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: { 'status' => 'completed', 'output' => [] })

    error = with_pdf { |pdf| assert_raises(Frijolero::LLM::APIError) { client(transport).extract(pdf, {}) } }

    assert_includes error.message, 'Failed to extract'
  end

  def test_extract_raises_when_the_response_fails
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: { 'status' => 'failed' })

    error = with_pdf { |pdf| assert_raises(Frijolero::LLM::APIError) { client(transport).extract(pdf, {}) } }

    assert_includes error.message, 'failed'
  end

  def test_poll_times_out_when_status_never_completes
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: { 'status' => 'queued' })

    error = with_pdf do |pdf|
      assert_raises(Frijolero::LLM::APIError) { client(transport, poll_timeout: 0.001).extract(pdf, {}) }
    end

    assert_includes error.message, 'timed out'
    assert_includes error.message, 'queued'
  end
end
