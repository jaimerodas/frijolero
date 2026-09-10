# frozen_string_literal: true

module Frijolero
  # The edit dialog of the journal. Reopens App to keep reports.rb the reports.
  class App
    helpers do
      # The journal reports absolute paths; the edit dialog works in ledger-relative ones.
      def ledger_relative(file)
        file.to_s.delete_prefix("#{File.expand_path(Config.ledger_dir)}/")
      end

      # `file` and `line` are checked by LedgerEdit itself: the trust boundary for both.
      def ledger_edit
        LedgerEdit.new(file: params[:file], line: params[:line], checker: self.class.reports)
      end
    end

    # One transaction as text, by file and line: {first, last, text}.
    get '/edit' do
      block = ledger_edit.block
      content_type :json
      JSON.generate(block)
    rescue LedgerEdit::NotFound
      halt 404, 'No existe esa transacción'
    end

    # The save writes the block, checks the whole ledger, and commits and pushes.
    # Every failure is plain text for the dialog; the file is back as it was on
    # 422, and saved but only committed locally on 502.
    post '/edit' do
      edit = ledger_edit
      text = edit.save(original: params[:original], edited: params[:content])
      self.class.repo.commit_and_push(edit.commit_message(original: params[:original], edited: text))
      status 204
    rescue LedgerEdit::NotFound
      halt 404, 'No existe esa transacción'
    rescue LedgerEdit::Stale
      halt 409, 'La transacción cambió en el ledger. Cierra el diálogo y vuelve a abrirla.'
    rescue LedgerEdit::Invalid => e
      halt 422, e.message
    rescue Reports::Error => e
      halt 502, "No se pudo validar el ledger: #{e.message}"
    rescue LedgerRepo::Error => e
      halt 502, "Guardado en el servidor, pero no se pudo subir: #{e.message}"
    end
  end
end
