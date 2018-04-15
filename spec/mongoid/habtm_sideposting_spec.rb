require 'rails_spec_helper'
require 'mongoid/models/mongoid_profile'
require 'mongoid/models/mongoid_tag'
require 'mongoid/resources/mongoid_profile_resource'

# Idea : Profile `has_and_belongs_to_many` Tags

if ENV["APPRAISAL_INITIALIZED"]
  RSpec.describe 'Mongoid HABTM sideposting', type: :controller do
    include JsonHelpers

    controller(ApplicationController) do
      jsonapi resource: MongoidProfileResource

      # Avoid strong params / strong resource for this test
      def params
        @params ||= begin
          hash = super.to_unsafe_h.with_indifferent_access
          hash = hash[:params] if hash.has_key?(:params)
          hash
        end
      end

      def create
        profile, success = jsonapi_create.to_a

        if success
          render_jsonapi(profile, scope: false)
        else
          render json: { error: 'payload' }
        end
      end

      def update
        profile, success = jsonapi_update.to_a

        if success
          render_jsonapi(profile, scope: false)
        else
          render json: { error: 'payload' }
        end
      end

      def destroy
        profile, success = jsonapi_destroy.to_a

        if success
          render json: { meta: {} }
        else
          render json: { error: profile.errors }
        end
      end
    end

    def do_post
      post :create, params: payload
    end

    def do_put(id)
      put :update, params: payload
    end

    before do
      @request.headers['Accept'] = Mime[:json]
      @request.headers['Content-Type'] = Mime[:json].to_s

      routes.draw {
        post "create" => "anonymous#create"
        put "update" => "anonymous#update"
        delete "destroy" => "anonymous#destroy"
      }
    end

    describe 'has_and_belongs_to_many nested relationship' do
      let(:tag_to_disassociate) { MongoidTag.create }
      let(:tag_to_associate) { MongoidTag.create }
      let(:tag_to_update) { MongoidTag.create(name: 'old') }
      let(:tag_to_destroy) { MongoidTag.create }
      let(:profile) { MongoidProfile.create }

      before do
        byebug
        profile.tags = [tag_to_disassociate, tag_to_update, tag_to_destroy]
        profile.save
      end

      let(:payload) do
        {
          data: {
            id: profile.id.to_s,
            type: 'profile',
            relationships: {
              tags: {
                data: [
                  { :'temp-id' => 'abc123', type: 'tags', method: 'create' },
                  { id: tag_to_update.id.to_s, type: 'tags', method: 'update' },
                  { id: tag_to_disassociate.id.to_s, type: 'tags', method: 'disassociate' },
                  { id: tag_to_destroy.id.to_s, type: 'tags', method: 'destroy' },
                  { id: tag_to_associate.id.to_s, type: 'tags', method: 'update' }
                ]
              }
            }
          },
          included: [
            {
              :'temp-id' => 'abc123',
              type: 'tags',
              attributes: { name: 'Created tag' }
            },
            {
              id: tag_to_update.id.to_s,
              type: 'tags',
              attributes: { name: 'Updated!' }
            },
            {
              id: tag_to_associate.id.to_s,
              type: 'tags'
            }
          ]
        }
      end

      it 'can create/update/disassociate/associate/destroy' do
        expect(profile.tags).to include(tag_to_destroy)
        expect(profile.tags).to include(tag_to_disassociate)
        do_put(profile.id)
        profile.reload
        expect(profile.tags).to_not include(tag_to_disassociate)
        expect(profile.tags).to_not include(tag_to_destroy)
        expect { tag_to_disassociate.reload }.to_not raise_error
        expect { tag_to_destroy.reload }.to raise_error(Mongoid::Errors::DocumentNotFound)
        expect(tag_to_update.reload.name).to include('Updated!')
        expect(profile.tags).to include(tag_to_associate)
        expect(profile.tags.detect { |tag| tag.name == 'Created tag' }).to be
      end
    end
  end
end
