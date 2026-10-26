# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

class OpenAIClientTest < Minitest::Test
  include TestHelpers

  # Each answer is a value, or an array that it answers in turn, the last one for good.
  class FakeTransport
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def post_json(path, body)
      @calls << [:post_json, path, body]
      path.end_with?('/cancel') ? { 'status' => 'cancelled' } : answer(:post_json)
    end

    def get(path)
      @calls << [:get, path]
      answer(:get)
    end

    private

    def answer(kind)
      value = @responses.fetch(kind)
      return value unless value.is_a?(Array)

      value.size > 1 ? value.shift : value.first
    end
  end

  COMPLETED = { 'status' => 'completed',
                'output' => [{ 'type' => 'message',
                               'content' => [{ 'type' => 'output_text', 'text' => '{"transactions":[]}' }] }],
                'usage' => { 'input_tokens' => 1000, 'output_tokens' => 500,
                             'input_tokens_details' => { 'cached_tokens' => 400 } } }.freeze
  SPEC = { '_prompt' => 'default', 'model' => 'gpt-5.6-sol' }.freeze

  def client(transport, **)
    Frijolero::OpenAIClient.new('test-key', transport: transport, poll_interval: 0, **)
  end

  def with_pdf(&)
    with_db_ledger do
      Tempfile.create(['statement', '.pdf']) do |f|
        f.write('%PDF-1.4')
        f.flush
        yield f.path
      end
    end
  end

  def test_extract_forwards_the_spec_with_the_pdf_inline_and_parses_the_answer
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: COMPLETED)
    format = { 'type' => 'json_schema', 'name' => 'transactions', 'strict' => true, 'schema' => { 'type' => 'object' } }
    spec = { '_prompt' => 'default', '_comment' => 'a note for humans, not the API', 'model' => 'gpt-5.6-sol',
             'instructions' => 'Extract the transactions.', 'format' => format,
             'reasoning' => { 'effort' => 'high', 'summary' => 'auto' } }

    result = with_pdf { |pdf| client(transport).extract(pdf, spec) }

    assert_equal({ 'transactions' => [] }, result)
    method, path, body = transport.calls.first
    assert_equal [:post_json, '/responses'], [method, path]
    refute body.key?('_comment'), 'comment keys must be stripped'
    refute body.key?('format'), 'format must move under text.format'
    assert_equal 'gpt-5.6-sol', body['model']
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
    spec = { '_prompt' => 'default', 'model' => 'gpt-5.6-sol', 'format' => { 'type' => 'json_schema' } }

    with_pdf { |pdf| client(transport).extract(pdf, spec) }

    assert_equal({ '_prompt' => 'default', 'model' => 'gpt-5.6-sol', 'format' => { 'type' => 'json_schema' } }, spec)
  end

  def test_extract_raises_when_the_response_has_no_text
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: { 'status' => 'completed', 'output' => [] })

    error = with_pdf { |pdf| assert_raises(Frijolero::LLM::APIError) { client(transport).extract(pdf, SPEC) } }

    assert_includes error.message, 'Failed to extract'
  end

  def test_extract_raises_when_the_response_fails
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: { 'status' => 'failed' })

    error = with_pdf { |pdf| assert_raises(Frijolero::LLM::APIError) { client(transport).extract(pdf, SPEC) } }

    assert_includes error.message, 'failed'
  end

  def test_poll_times_out_when_status_never_completes
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: { 'status' => 'queued' })

    error = with_pdf do |pdf|
      assert_raises(Frijolero::LLM::APIError) { client(transport, poll_timeout: 0.001).extract(pdf, SPEC) }
    end

    assert_includes error.message, 'timed out'
    assert_includes error.message, 'queued'
  end

  def test_a_timeout_cancels_the_response
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: { 'status' => 'in_progress' })

    with_pdf do |pdf|
      assert_raises(Frijolero::LLM::APIError) { client(transport, poll_timeout: 0.001).extract(pdf, SPEC) }
    end

    assert_equal [:post_json, '/responses/resp-1/cancel'], transport.calls.last.first(2)
  end

  # OpenAI sometimes leaves a background response queued for good, while the same
  # request, sent again, finishes in seconds.
  def test_a_response_stuck_in_the_queue_is_cancelled_and_sent_again
    transport = FakeTransport.new(post_json: [{ 'id' => 'resp-1' }, { 'id' => 'resp-2' }],
                                  get: [{ 'status' => 'queued' }, COMPLETED])

    result = with_pdf { |pdf| client(transport, queue_limit: 0).extract(pdf, SPEC) }

    assert_equal({ 'transactions' => [] }, result)
    expected = [[:post_json, '/responses'], [:get, '/responses/resp-1'], [:post_json, '/responses/resp-1/cancel'],
                [:post_json, '/responses'], [:get, '/responses/resp-2']]
    assert_equal(expected, transport.calls.map { |call| call.first(2) })
    assert_equal transport.calls[0][2], transport.calls[3][2], 'the same request, sent again'
  end

  def test_a_response_stuck_twice_fails_and_both_are_cancelled
    transport = FakeTransport.new(post_json: [{ 'id' => 'resp-1' }, { 'id' => 'resp-2' }],
                                  get: { 'status' => 'queued' })

    error = with_pdf do |pdf|
      assert_raises(Frijolero::LLM::APIError) { client(transport, queue_limit: 0).extract(pdf, SPEC) }
    end

    assert_includes error.message, 'queued'
    cancels = transport.calls.filter_map { |_, path| path if path.end_with?('/cancel') }
    assert_equal ['/responses/resp-1/cancel', '/responses/resp-2/cancel'], cancels
  end

  # The queue limit is for a response that never starts; a slow one is work in progress.
  def test_a_response_in_progress_is_not_sent_again
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: [{ 'status' => 'in_progress' }, COMPLETED])

    with_pdf { |pdf| client(transport, queue_limit: 0).extract(pdf, SPEC) }

    assert_equal(1, transport.calls.count { |_, path| path == '/responses' })
    refute(transport.calls.any? { |_, path| path.end_with?('/cancel') })
  end

  # 600 fresh * 4.00 + 400 cached * 0.40 + 500 * 20.00 = 12560 micro-dollars.
  def test_a_completed_call_records_its_usage
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: COMPLETED)

    with_pdf do |pdf|
      client(transport).extract(pdf, SPEC)

      row = Frijolero::DB.first('SELECT * FROM usage')
      assert_equal ['default', 'gpt-5.6-sol', 1000, 400, 500, 12_560],
                   row.values_at('prompt', 'model', 'input_tokens', 'cached_tokens', 'output_tokens', 'cost_micros')
      assert_equal 1, Frijolero::DB.first('SELECT COUNT(*) AS n FROM usage')['n']
    end
  end

  def test_the_usage_is_recorded_even_when_the_text_is_missing
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' },
                                  get: { 'status' => 'completed', 'output' => [], 'usage' => COMPLETED['usage'] })

    with_pdf do |pdf|
      assert_raises(Frijolero::LLM::APIError) { client(transport).extract(pdf, SPEC) }

      assert_equal 1, Frijolero::DB.first('SELECT COUNT(*) AS n FROM usage')['n']
    end
  end

  def test_a_response_without_usage_records_zeros_and_warns
    sink = StringIO.new
    Frijolero::Log.sink = sink
    transport = FakeTransport.new(post_json: { 'id' => 'resp-1' }, get: COMPLETED.except('usage'))

    with_pdf do |pdf|
      client(transport).extract(pdf, SPEC)

      assert_equal [0, 0, 0],
                   Frijolero::DB.first('SELECT * FROM usage').values_at('input_tokens', 'output_tokens',
                                                                        'cost_micros')
    end
    assert_includes sink.string, 'no usage'
  ensure
    Frijolero::Log.sink = $stdout
  end
end
