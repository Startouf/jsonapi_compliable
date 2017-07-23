module JsonapiCompliable
  module Adapters
    # Mongoid Sideloading capabilities. Tightly coupled with Mongoid's semi-private internals
    #
    # @author [Cyril]
    #
    module MongoidSideloading
      # Note : this module relies on Mongoid code related to loading relations
      # Unfortunately there's not a lot of documentation about this, best is to have a look directly at Mongoid's code
      # Unlike ActiveRecord, we don't have #_loaded! methods to flag the association as loaded
      # Instead Mongoid used class variables of the same name as the association
      #
      # Have a look at
      # - Mongoid Accessors : https://github.com/mongodb/mongoid/blob/master/lib/mongoid/association/accessors.rb
      #   in a nutshell, Mongoid uses instance variables @_{association_name} to memoize associations
      #   The goal is : make the query by yourself, and ensure #needs_no_database_query? returns true
      #   It would seem using #set_relation does the thing !
      #
      # Compared to the ActiveRecord adapter, this module takes advantage of Mongoid::Relation metadata
      # to infer a default foreign_key and child_scope for associations

      # Adapter to retrieve association metadata
      # Used to infer various properties like foreign/local keys already defined in models
      #
      # @param object [Object.includes(Mongoid::Document)] A Mongoid Document model
      # @param association_name [Symbol] Name of association
      #
      # @return [Hash] Metadata information
      def association_metadata(association_name)
        @metadata ||= begin
          model_class = self.resource.class.config[:model]
          if model_class.nil?
            raise RuntimeError, "Declare a 'model' in the resource #{self.resource.class.name} for sideloading, "\
              "or a :foreign_key in the resource association for #{association_name}"
          end
          model_class.relations[association_name.to_s]
        end
      end

      # @Override implementation for Mongoid, should be pretty similar to AR
      def has_many(association_name, scope: nil, resource:, foreign_key: nil, primary_key: :id, &blk)
        child_scope = scope

        foreign_key ||= association_metadata(association_name).try(:foreign_key)

        allow_sideload association_name, type: :has_many, resource: resource, foreign_key: foreign_key, primary_key: primary_key do
          scope do |parents|
            child_scope ||= parents.klass.relations[association_name.to_s].try(:klass)

            parent_ids = parents.map { |p| p.send(primary_key) }.uniq.compact
            child_scope.in(foreign_key => parent_ids)
          end

          assign do |parents, children|
            parents.each do |parent|
              parent_identifier = parent.send(primary_key)
              relevant_children = children.select { |child| child.send(foreign_key) == parent_identifier }
              parent.set_relation(association_name, relevant_children)
            end
          end

          instance_eval(&blk) if blk
        end
      end

      # TODO: Mongoid embeds_many sideload needs to filter embedded records according to the scope !!
      # (Currently only works with default scope)
      #
      # @param association_name [Symbol]
      # @param scope: nil [Mongoid::Criteria]
      # @param resource: nil [JsonapiCompliable::Resource]
      #
      # @return [void]
      def embeds_many(association_name, scope: nil, resource: nil)
        allow_sideload association_name, type: :embeds_many, resource: resource, foreign_key: foreign_key, primary_key: primary_key do
          # They are already loaded :yay:
          scope {}
          assign {}
        end

        # TODO: still need to still apply scope filtering :'(
        instance_eval(yield) if block_given?
      end

      # @Override implementation for Mongoid, should be pretty similar to AR
      # @example
      #
      #   conversation has_many :messages, message belongs_to :conversation
      #   => parent = message, child = conversation
      #   => the foreign_key :conversation_id is in the parent
      #
      def belongs_to(association_name, scope: nil, resource:, foreign_key: nil, primary_key: :id, &blk)
        child_scope = scope
        foreign_key ||= association_metadata(association_name).try(:foreign_key)

        allow_sideload association_name, type: :belongs_to, resource: resource, foreign_key: foreign_key, primary_key: primary_key do
          scope do |parents| # parents = conversations_criteria
            child_scope ||= parents.klass.relations[association_name.to_s].try(:klass)
            # Collect Conv IDs
            children_ids = parents.map { |parent| parent.send(foreign_key) }
            child_scope.in(primary_key => children_ids.uniq.compact)
          end

          assign do |parents, children|
            parents.each do |parent|
              parent_identifier = parent.send(primary_key)
              relevant_child = children.find { |c| c.send(primary_key) == parent_identifier }
              parent.set_relation(association_name, relevant_child)
            end
          end
        end
      end

      # HABTM in Mongoid stores the keys locally in an array
      #
      #   in Memory  : model.association_ids #=> [BSON::ObjectID('cafebabe'), BSON::ObjectID('badf00d'), ...]
      #   Serialized : model.association_ids #=> ['cafebabe', 'badf00d', ... }
      #
      # Therefore the :primary_key and :foreign_key have little meaning here
      #   the foreign_keys_key holds the document IDs that need to be sideloaded
      #   Document IDs are always used (as far as I know...)
      #
      # the :foreign_key used here still refers to the attribute of to-be-fetched objects
      #   that should match one of the keys in the foreign_keys_key
      #
      # @param association_name [Symbol] Association name
      # @param scope: nil [type] [description]
      # @param resource: [type] [description]
      #
      # @param foreign_key: [type] Accessor to the array of foreign keys
      # @param primary_key: :id [Symbol] IRRELEVANT
      # @param &blk [type] [description]
      #
      # @return [type] [description]
      def has_and_belongs_to_many(association_name, scope: nil, resource:, foreign_key: nil, foreign_keys_key: nil, primary_key: :id, &blk)
        child_scope = scope
        foreign_keys_key ||= "#{association_name.to_s.singularize}_ids"
        foreign_key = :id # for compatibility reasons with #allow_sideload

        allow_sideload association_name, type: :habtm, resource: resource, foreign_key: foreign_key, primary_key: primary_key do
          scope do |parents|
            # TODO : merge selectors with ORs
            child_scope ||= parents.klass.relations[association_name.to_s].try(:klass)
            sideload_ids = parents.flat_map { |p| p.send(foreign_keys_key) }.uniq.compact
            child_scope.in(id: sideload_ids)
          end

          assign do |parents, foreign_objects|
            parents.each do |local_object|
              # Assign foreign objects if their ID is in the ID list of the parent
              local_keys = local_object.send(foreign_keys_key)
              relevant_foreign_objects = foreign_objects.select do |foreign_object|
                local_keys.include?(foreign_object.id)
              end
              local_object.set_relation(association_name, relevant_foreign_objects)
            end
          end
        end

        instance_eval(&blk) if blk
      end

      # @Override implementation for Mongoid, should be pretty similar to AR
      def polymorphic_belongs_to(association_name, group_by:, groups:, &blk)
        allow_sideload association_name, type: :polymorphic_belongs_to, polymorphic: true do
          group_by group_by

          groups.each_pair do |type, config|
            primary_key = config[:primary_key] || :id
            foreign_key = config[:foreign_key]

            allow_sideload type, primary_key: primary_key, foreign_key: foreign_key, type: :belongs_to, resource: config[:resource] do
              scope do |parents|
                parent_ids = parents.map { |p| p.send(foreign_key) }
                parent_ids.compact!
                parent_ids.uniq!
                config[:scope].call.where(primary_key => parent_ids)
              end

              assign do |parents, children|
                parents.each do |parent|
                  parent_identifier = parent.send(primary_key)
                  relevant_child = children.find { |c| c.send(primary_key) == parent_identifier }
                  parent.set_relation(association_name, relevant_child)
                end
              end
            end
          end

          instance_eval(&blk) if blk
        end
      end
    end
  end
end