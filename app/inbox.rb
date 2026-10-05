# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'

module Frijolero
  # The Bandeja: the uploads that wait for a person to confirm them. Each one is a
  # directory under incoming/, named by a random token, with the PDF under its original
  # name and, once the classifier answered, classification.json. All of it is on disk.
  class Inbox
    ANSWER = 'classification.json'
    TOKEN = /\A\h{16}\z/

    Item = Struct.new(:token, :pdf, :answer, :added_at) do
      def filename = File.basename(pdf)
      def account = answer&.[]('account')
      def period = answer&.[]('period')

      # "<account> <period>" when the answer names a known account and a period, else nil.
      def label
        "#{account} #{period}" if Config.accounts.key?(account) && period.to_s.match?(/\A\d{4}\z/)
      end
    end

    # status is what the upload needs: :classifying, :error (the classifier failed),
    # :failed (its job failed), :unknown, :exists, :repeated (another upload has the
    # same label) or :ready. job is the newest job of the upload, or nil.
    Row = Struct.new(:item, :status, :job)

    def initialize(dir)
      @dir = dir
    end

    # Each upload that no queued or running job holds, oldest first. `jobs` is newest first.
    def rows(jobs)
      rows = waiting(jobs)
      labels = rows.filter_map { |row| row.item.label }.tally
      rows.each { |row| row.status = status(row, labels) }
    end

    # A new upload: a copy of `source` under `name`, in a directory of its own.
    def add(source, name)
      token = SecureRandom.hex(8)
      FileUtils.mkdir_p(File.join(@dir, token))
      FileUtils.cp(source, File.join(@dir, token, name))
      find(token)
    end

    # Every upload that still has its PDF, oldest first. Statement deletes the PDF after
    # the extraction, so a job that fails later leaves a directory without one.
    def items
      tokens = Dir.exist?(@dir) ? Dir.children(@dir) : []
      tokens.filter_map { |token| find(token) }.sort_by(&:added_at)
    end

    # The upload of `token`, or nil. The token check keeps a request inside incoming/.
    def find(token)
      return unless token.to_s.match?(TOKEN)

      dir = File.join(@dir, token)
      pdfs = Dir.children(dir).grep(/\.pdf\z/i)
      return unless pdfs.size == 1

      pdf = File.join(dir, pdfs.first)
      answer = File.join(dir, ANSWER)
      Item.new(token, pdf, File.exist?(answer) ? JSON.parse(File.read(answer)) : nil, File.mtime(pdf))
    rescue SystemCallError # no such upload, or a job removed it during the read
      nil
    end

    # Through a rename, so a page never reads half an answer.
    def record(token, answer)
      path = File.join(@dir, token, ANSWER)
      File.write("#{path}.tmp", JSON.generate(answer))
      File.rename("#{path}.tmp", path)
    end

    def discard(token)
      FileUtils.rm_rf(File.join(@dir, token))
    end

    private

    def waiting(jobs)
      items.map { |item| Row.new(item, nil, jobs.find { |job| job.token == item.token }) }
           .reject { |row| row.job&.done? == false }
    end

    # First where the upload is in the process, then what its answer says.
    def status(row, labels)
      return :classifying unless row.item.answer
      return :error if row.item.answer['error']
      return :failed if row.job&.status == 'failed'

      answer_status(row.item, labels)
    end

    def answer_status(item, labels)
      return :unknown unless item.label
      return :exists if File.exist?(Config.statement_path(item.account, item.period, 'beancount'))

      labels[item.label] > 1 ? :repeated : :ready
    end

    # One thread that classifies new uploads in order. It is not the job worker, so an
    # extraction never holds up the Bandeja. The queue is in memory, so a new worker
    # takes back every upload without an answer: a restart loses nothing.
    class Worker
      def initialize(inbox, &classify)
        @inbox = inbox
        @classify = classify
        @queue = Queue.new
        inbox.items.reject(&:answer).each { |item| push(item.token) }
      end

      def push(token) = @queue.push(token)

      def start
        @start ||= Thread.new { loop { work_one } }
      end

      def work_one
        token = @queue.pop
        item = @inbox.find(token)
        @inbox.record(token, answer(item.pdf)) if item
        token
      rescue SystemCallError # discarded, or processed, while the model answered
        token
      end

      private

      def answer(pdf)
        @classify.call(pdf)
      rescue StandardError => e
        { error: e.message }
      end
    end
  end
end
