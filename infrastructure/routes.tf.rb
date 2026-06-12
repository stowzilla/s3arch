# frozen_string_literal: true

TerraDispatch.routes.draw do
  namespace :s3arch, tables: [:search_indexes] do
    get '/', action: 'index', auth: :none
    post '/rebuild', action: 'rebuild', auth: :cognito
  end
end
