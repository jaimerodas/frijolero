# frozen_string_literal: true

require "sinatra/base"
require "json"

module Frijolero
  module Web
    class App < Sinatra::Base
      set :views, File.join(__dir__, "views")
      set :public_folder, File.join(__dir__, "public")
      set :static_cache_control, [:no_cache]

      # Configured at launch by CLI
      set :json_file, nil
      set :beancount_account, nil
      set :accounts_list, []

      get "/" do
        transactions = load_transactions
        erb :review, locals: {
          transactions: transactions,
          accounts: settings.accounts_list,
          filename: File.basename(settings.json_file),
          beancount_account: settings.beancount_account
        }
      end

      put "/transactions" do
        content_type :json
        data = JSON.parse(request.body.read)
        save_transactions(data["transactions"])
        {status: "ok"}.to_json
      end

      post "/convert" do
        content_type :json
        data = JSON.parse(request.body.read)
        save_transactions(data["transactions"])

        output = BeancountConverter.convert(
          input: settings.json_file,
          account: settings.beancount_account
        )

        {status: "ok", output: output}.to_json
      end

      post "/convert-and-merge" do
        content_type :json
        data = JSON.parse(request.body.read)
        save_transactions(data["transactions"])

        beancount_path = BeancountConverter.convert(
          input: settings.json_file,
          account: settings.beancount_account
        )

        BeancountMerger.new(
          files: [beancount_path],
          output: Config.beancount_main_file
        ).run

        {status: "ok", output: beancount_path}.to_json
      end

      private

      def load_transactions
        JSON.parse(File.read(settings.json_file)).fetch("transactions", [])
      end

      def save_transactions(transactions)
        File.write(
          settings.json_file,
          JSON.pretty_generate({"transactions" => transactions})
        )
      end
    end
  end
end
