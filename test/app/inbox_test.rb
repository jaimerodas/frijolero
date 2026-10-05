# frozen_string_literal: true

require 'test_helper'
require 'fileutils'

class InboxTest < Minitest::Test
  include TestHelpers

  def setup
    @dir = Dir.mktmpdir
    @source = File.join(@dir, 'source.pdf')
    File.write(@source, "%PDF-1.4\n")
    @inbox = Frijolero::Inbox.new(File.join(@dir, 'incoming'))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_add_keeps_the_original_name_in_a_directory_of_its_own
    item = @inbox.add(@source, 'Estado de cuenta.pdf')

    assert_match(/\A\h{16}\z/, item.token)
    assert_equal 'Estado de cuenta.pdf', item.filename
    assert File.exist?(item.pdf)
    assert_nil item.answer
  end

  def test_a_recorded_answer_comes_back_with_the_item
    item = @inbox.add(@source, 'a.pdf')

    @inbox.record(item.token, account: 'AMEX', period: '2608')

    assert_equal({ 'account' => 'AMEX', 'period' => '2608' }, @inbox.find(item.token).answer)
    assert_equal ['a.pdf', 'classification.json'], Dir.children(File.dirname(item.pdf)).sort
  end

  def test_items_are_the_uploads_with_a_pdf_oldest_first
    first = @inbox.add(@source, 'a.pdf')
    second = @inbox.add(@source, 'b.pdf')
    File.utime(Time.now - 60, Time.now - 60, first.pdf)
    File.utime(Time.now, Time.now, second.pdf)
    gone = @inbox.add(@source, 'c.pdf')
    File.delete(gone.pdf) # Statement deletes the PDF after the extraction

    assert_equal [first.token, second.token], @inbox.items.map(&:token)
  end

  def test_items_of_a_missing_directory_are_none
    assert_empty @inbox.items
  end

  def test_find_refuses_a_token_that_could_leave_the_directory
    @inbox.add(@source, 'a.pdf')

    assert_nil @inbox.find('../incoming')
    assert_nil @inbox.find('0' * 16)
  end

  def test_discard_removes_the_upload
    item = @inbox.add(@source, 'a.pdf')

    @inbox.discard(item.token)

    assert_nil @inbox.find(item.token)
  end

  def test_the_worker_records_the_answer_of_each_pushed_upload
    item = @inbox.add(@source, 'a.pdf')
    worker = Frijolero::Inbox::Worker.new(@inbox) { |pdf| { account: 'AMEX', period: File.basename(pdf, '.pdf') } }

    worker.push(item.token)
    worker.work_one

    assert_equal({ 'account' => 'AMEX', 'period' => 'a' }, @inbox.find(item.token).answer)
  end

  def test_an_error_becomes_the_answer_and_the_worker_goes_on
    bad = @inbox.add(@source, 'bad.pdf')
    good = @inbox.add(@source, 'good.pdf')
    worker = Frijolero::Inbox::Worker.new(@inbox) do |pdf|
      raise Frijolero::LLM::RateLimitError.new('rate limited', status: 429) if pdf.end_with?('bad.pdf')

      { account: 'AMEX' }
    end

    worker.push(bad.token)
    worker.push(good.token)
    worker.work_one
    worker.work_one

    assert_equal({ 'error' => 'rate limited' }, @inbox.find(bad.token).answer)
    assert_equal({ 'account' => 'AMEX' }, @inbox.find(good.token).answer)
  end

  def test_an_upload_discarded_before_its_turn_is_skipped
    item = @inbox.add(@source, 'a.pdf')
    calls = 0
    worker = Frijolero::Inbox::Worker.new(@inbox) { calls += 1 }

    worker.push(item.token)
    @inbox.discard(item.token)
    worker.work_one

    assert_equal 0, calls
    refute Dir.exist?(File.dirname(item.pdf))
  end

  # The job removes the directory when it ends well; the answer then has nowhere to go.
  def test_an_upload_removed_while_the_model_answers_does_not_stop_the_worker
    item = @inbox.add(@source, 'a.pdf')
    worker = Frijolero::Inbox::Worker.new(@inbox) do
      @inbox.discard(item.token)
      { account: 'AMEX' }
    end

    worker.push(item.token)

    assert_equal item.token, worker.work_one
    refute Dir.exist?(File.dirname(item.pdf))
  end

  # The queue is in memory: after a restart, the worker takes back the uploads without an answer.
  def test_a_new_worker_queues_every_upload_without_an_answer
    waiting = @inbox.add(@source, 'a.pdf')
    answered = @inbox.add(@source, 'b.pdf')
    @inbox.record(answered.token, account: 'AMEX')
    seen = []
    worker = Frijolero::Inbox::Worker.new(@inbox) do |pdf|
      seen << pdf
      { account: 'BBVA' }
    end

    worker.work_one

    assert_equal [waiting.pdf], seen
    assert_equal({ 'account' => 'AMEX' }, @inbox.find(answered.token).answer)
  end
end
