# frozen_string_literal: true

require_relative 'page'

module Frijolero
  # /profile, "Mi cuenta": the name and the email of the signed-in user, their ledgers, the
  # use of the model month by month, and the link to their passkeys. Each action redirects
  # back to /profile with the code of its message.
  class ProfilePage < Page
    NOTICES = {
      'name' => 'Nombre guardado.',
      'ledger_deleted' => 'Ledger borrado.'
    }.freeze

    get '/profile' do
      erb :profile, locals: { notice: NOTICES[params['notice']] }
    end

    post '/profile/name' do
      Users.rename(user.id, params['name'])
      redirect '/profile?notice=name', 303
    end
  end
end
