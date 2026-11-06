# frozen_string_literal: true

require 'fileutils'
require 'date'

module Frijolero
  # Upload PDFs, from the web form or the iOS Shortcut. They wait in the Bandeja (Inbox),
  # where a thread classifies them, until a person confirms them and a job runs.
  class App
    # The Bandeja's word and glyph for each status. ▲ needs a person; ■ failed.
    INBOX_STATUS = { classifying: %w[running clasificando], ready: %w[ok listo],
                     error: ['failed', 'no se clasificó'], failed: %w[failed falló],
                     unknown: ['missing', 'sin identificar'], exists: ['missing', 'ya existe'],
                     repeated: %w[missing repetido] }.freeze

    # The days after the cutoff day that a statement can still close on its own. Measured
    # on 68 statements: 66 closed on the day, and 2 the day after. Never the day before: a
    # statement that closes on the 31st, read as an account that closes on the 1st, would pass.
    CUTOFF_SLACK = 0..1

    # No account, no upload: the classifier would spend a model call and the
    # Bandeja could not name an account.
    before '/upload*' do
      redirect '/accounts/new', 303 if Config.accounts.empty?
    end

    get '/upload' do
      erb :upload
    end

    # One or more PDFs. The answer does not wait for the model: the Bandeja shows each
    # PDF as the classifier gets to it.
    post '/upload' do
      pdfs = uploaded_pdfs
      halt 422, 'Sube solo archivos PDF' unless pdfs

      add_to_inbox(pdfs)
      redirect '/inbox', 303
    end

    # The share sheet's way in (an iOS Shortcut); Login checks the token. Every answer is
    # JSON, the errors too: a Shortcut reads a body more easily than a status.
    post '/api/upload' do
      content_type :json
      halt 422, JSON.generate(error: 'Primero da de alta una cuenta') if Config.accounts.empty?
      pdfs = uploaded_pdfs
      halt 422, JSON.generate(error: 'Sube un PDF') unless pdfs

      add_to_inbox(pdfs)
      status 202
      # /api/ has no ledger prefix, so the link names the token's ledger itself.
      JSON.generate(inbox: url("/l/#{Ledger.current.id}/inbox"))
    end

    get '/inbox' do
      erb :inbox, locals: { rows: inbox_rows }
    end

    # One button for one row and for "Procesar los listos": `tokens` lists the rows,
    # and each row sends its own account[token], period[token] and overwrite[token].
    post '/inbox/process' do
      extraction_allowed!
      choices = params[:tokens].to_s.split.uniq.map { |token| inbox_choice(token) }
      halt 422, 'Nada que procesar' if choices.empty?

      jobs = choices.map { |choice| self.class.enqueue_inbox(*choice) }
      redirect(jobs.one? ? "/jobs/#{jobs.first.id}" : '/jobs', 303)
    end

    # Only the PDF: no model, no ledger, no job. The put takes seconds, so it runs in the
    # request. The upload goes once the bucket has the PDF.
    post '/inbox/backup' do
      item, account, period = inbox_choice(params[:token])
      self.class.s3.put(Config.pdf_key(account, period), item.pdf)
      FileUtils.rm_rf(File.dirname(item.pdf))
      redirect '/inbox', 303
    rescue S3::Error => e
      halt 502, "No se pudo guardar el PDF: #{Rack::Utils.escape_html(e.message)}"
    end

    post '/inbox/discard' do
      self.class.inbox.discard(inbox_item!(params[:token]).token)
      redirect '/inbox', 303
    end

    private

    # [[the temp file, the original name], …] of the uploaded files, or nil unless there
    # is at least one and each one is a PDF. The web form sends pdf[], the Shortcut pdf.
    def uploaded_pdfs
      files = [params[:pdf]].flatten.compact
      names = files.map { |file| upload_name(file) }
      return if names.empty? || !names.all? { |name| name.match?(/\.pdf\z/i) }

      files.map { |file| file[:tempfile].path }.zip(names)
    end

    # Each PDF in a directory of its own, under its original name, which is what lets
    # Classifier's filename shortcut fire. Then the classifier thread takes it.
    def add_to_inbox(pdfs)
      pdfs.each { |source, name| self.class.inbox_worker.push(self.class.inbox.add(source, name).token) }
    end

    # Rack leaves a plain multipart filename as BINARY; browsers send it as UTF-8.
    def upload_name(file)
      return '' unless file.is_a?(Hash)

      file[:filename].to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def inbox_item!(token)
      self.class.inbox.find(token) || halt(422, 'Token inválido')
    end

    def inbox_rows = self.class.inbox.rows(self.class.jobs.all)

    # [item, account, period, overwrite] of one Bandeja row, or a 422.
    def inbox_choice(token)
      item = inbox_item!(token)
      account = row_param(:account, token)
      period = row_param(:period, token)
      halt 422, 'Cuenta inválida' unless Config.accounts.key?(account)
      halt 422, 'Periodo inválido' unless period.to_s.match?(/\A\d{4}\z/)

      [item, account, period, row_param(:overwrite, token) == '1']
    end

    def row_param(name, token) = params[name].is_a?(Hash) ? params[name][token] : nil

    # From a request (Procesar, Reintentar) and from the Bandeja's thread (auto_process).
    class << self
      # The choice becomes the answer, so a row whose job fails comes back as the person
      # left it. The printed period end, when there is one, fills in the cutoff day.
      def enqueue_inbox(item, account, period, overwrite)
        answer = (item.answer || {}).except('error', 'waits').merge('account' => account, 'period' => period)
        inbox.record(item.token, answer)
        period_end = iso_date(answer['period_end'])
        enqueue_statement(account: account, period: period, pdf_path: item.pdf, overwrite: overwrite) do
          AccountConfig.record_cutoff(account, period_end) if period_end
        end
      end

      # The collaborators are read here rather than inside the block: the block runs on
      # the worker thread, which has no ledger of its own.
      def enqueue_statement(account:, period:, pdf_path:, overwrite:, &after)
        statement = Statement.new(pdf_path, client: client, s3: s3, account: account, period: period,
                                            overwrite: overwrite)
        run_job(account, period, statement, File.dirname(pdf_path), &after)
      end

      # Procesar without the click, once the classifier's answer is saved. A ready upload
      # that auto_hold keeps, or whose step fails, waits in the Bandeja with the reason.
      def auto_process(token)
        item = ready(token)
        return unless item

        reason = auto_hold(item)
        reason ? wait(item, reason) : enqueue_inbox(item, item.account, item.period, false)
      rescue StandardError => e
        wait(item, e.message) if item
      end

      private

      # The upload of `token` while the Bandeja calls it ready and there is a model to extract it.
      def ready(token)
        inbox.rows(jobs.all).find { |row| row.item.token == token && row.status == :ready }&.item if client
      end

      def wait(item, reason) = inbox.record(item.token, item.answer.merge('waits' => reason))

      # Why a ready upload waits for a person, or nil: it goes on its own only when it is
      # the statement that the dashboard expects next, or when the person named the file.
      def auto_hold(item)
        return 'llegaste al límite del mes' if Usage.capped?(Ledger.current.owner_id)
        return "ya hay una corrida de #{item.label}" if jobs.pending(item.label)

        off_schedule(item.account, item.period, item.answer['period_end']) unless item.named?
      end

      # Why a statement is not the one that the dashboard expects next, or nil.
      def off_schedule(account, period, period_end)
        day = Config.accounts[account]['cutoff_day']
        return 'la cuenta aún no tiene día de corte' unless day

        closing = Dashboard.last_closing(day)
        expected = (closing - 15).strftime('%y%m')
        return "el último periodo cerrado es #{expected}" unless period == expected

        printed = iso_date(period_end)
        "cerró el #{period_end} y su corte es el día #{day}" unless printed && CUTOFF_SLACK.cover?(printed - closing)
      end

      # The printed period end is optional: the filename shortcut has none.
      def iso_date(value)
        Date.iso8601(value.to_s)
      rescue Date::Error
        nil
      end

      # Pull before the work and push after it, so the statement is written on top of
      # the latest ledger; a job that fails leaves the upload where it is, for a retry.
      # The block runs after a good statement and rides on the same commit. The worker
      # thread has no ledger of its own, so the body takes the caller's. The pull holds
      # the ledger's lock, and so do the writes with the block and the commit; the model
      # calls between them and after them (Revisar's guesses) do not.
      def run_job(account, period, statement, upload_dir, &after)
        repo = self.repo
        client = self.client
        ledger = Ledger.current
        label = "#{account} #{period}"
        jobs.push(label: label, token: File.basename(upload_dir)) do
          Ledger.with(ledger) do
            process_statement(repo, statement, label, upload_dir, after)
            suggest_after_job(client, account, period)
          end
        end
      end

      def process_statement(repo, statement, label, upload_dir, after)
        Ledger.lock { repo.pull }
        status = statement.process do
          after&.call
          repo.commit_and_push(label)
        end
        raise "Statement terminó con #{status}" unless status == Statement::OK

        FileUtils.rm_rf(upload_dir)
      end
    end
  end
end
