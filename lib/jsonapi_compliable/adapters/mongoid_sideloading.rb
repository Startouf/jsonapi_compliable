module JsonapiCompliable
  module Adapters
    # Mongoid Sideloading capabilities. Tightly coupled with Mongoid's semi-private internals
    #
    # @author [Cyril]
    #
    module MongoidSideloading
      class UnresolvableSideloadingCriteria < RuntimeError; end

      # Useful error message for when a default foreign key cannot be inferred
      #
      # @author [Cyril]
      #
      class UnresolvableForeignKey < RuntimeError
        def initialize(association_name, resource_class)
          @association_name = association_name
          @resource_class = resource_class
        end

        def message
          'Could not infer a default foreign key for the association ' +
            "#{@association_name} on the resource '#{@resource_class}'. " \
            'Try setting a :foreign_key param in the sideloading definition'
        end
      end

      # Note : this module needs to know the internals of Mongoid especially related to laoding relations
      # Unfortunately there's not a lot of documentation about this, best is to have a look directly at Mongoid's code
      # Especially, have a look at
      # - Mongoid Accessors : https://github.com/mongodb/mongoid/blob/master/lib/mongoid/association/accessors.rb
      #   in a nutshell, Mongoid uses instance variables @_{association_name} to memoize associations
      #   The goal is : Query by yourself, and make #needs_no_database_query? returns true
      #   It would seem using #set_relation does the thing !
      #   (equivalent of ActiveRecord's #loaded! method)

      # Adapter to retrieve association metadata
      # Used to infer various properties like foreign/local keys already defined in models
      #
      # @param resolved_scope [Array<?> or <?>] resolved scope containing models
      # @param association_name [Symbol] Name of association
      #
      # @return [Hash] Metadata information
      def association_metadata(resolved_scope, association_name)
        @metadata ||= begin
          if resolved_scope.is_a?(Array)
            resolved_scope.first.class
          else
            resolved_scope.klass
          end.relations[association_name.to_s]
        end
      end

      def association_class
        resource.config[:model]
      end

      def raise_if_no_model!(association_name)
        raise RuntimeError, "Declare a 'model' in the resource #{resource.class.name} for sideloading !\n"\
          "or a :foreign_key in the resource association for #{association_name}"
      end

      # Attempt to Infer a default child scope for a relation
      # Note : may return bad results in case of polymorphic data types that would have different foreign ID, etc.
      # (either use manual allow_sideload or specify :scope in that case)
      #
      # @param resolved_scope [Array<?>] the resolved parents
      # @param association_name [Symbol]
      #
      # @return [Mongoid::Criteria<?>]
      def infer_default_child_scope(resolved_scope, association_name)
        inferred_scope = association_metadata(resolved_scope, association_name) \
          &.klass&.all
        raise UnresolvableSideloadingCriteria if inferred_scope.nil?
        inferred_scope
      end

      # Attempt to infer the foreign key for a has_x relation
      # @param association_name [Symbol]
      # @raise [UnresolvableForeignKey]
      #
      # @return [Symbol] Foreign key attribute
      def infer_foreign_key(resolved_scope, association_name)
        foreign_key = association_metadata(resolved_scope, association_name)&.foreign_key
        raise UnresolvableForeignKey.new(association_name, resource.class) if foreign_key.nil?
        foreign_key
      end

      # @Override implementation for Mongoid, should be pretty similar to AR
      def has_many(association_name, scope: nil, resource:, foreign_key: nil, primary_key: :id, &blk)
        child_scope = scope

        allow_sideload association_name, type: :has_many, resource: resource, foreign_key: foreign_key, primary_key: primary_key do
          scope do |parents|
            foreign_key ||= infer_foreign_key(parents, association_name)
            child_scope ||= infer_default_child_scope(parents, association_name)

            parent_ids = parents.map { |p| p.send(primary_key) }.uniq.compact
            child_scope.in(foreign_key => parent_ids)
          end

          assign do |parents, children|
            foreign_key ||= infer_foreign_key(parents, association_name)

            parents.each do |parent|
              # parent.relations(association_name).loaded!
              parent_identifier = parent.send(primary_key)
              relevant_children = children.select { |child| child.send(foreign_key) == parent_identifier }
              parent.set_relation(association_name, relevant_children)
            end
          end

          instance_eval(&blk) if blk
        end
      end

      # @Override implementation for Mongoid, should be pretty similar to AR
      # Compared to has_many we just use `detect` instead of `select` when assignin children
      def has_one(association_name, scope: nil, resource:, foreign_key: nil, primary_key: :id, &blk)
        child_scope = scope

        allow_sideload association_name, type: :has_one, resource: resource, foreign_key: foreign_key, primary_key: primary_key do
          scope do |parents|
            foreign_key ||= infer_foreign_key(parents, association_name)
            child_scope ||= infer_default_child_scope(parents, association_name)

            parent_ids = parents.map { |p| p.send(primary_key) }.uniq.compact
            child_scope.in(foreign_key => parent_ids)
          end

          assign do |parents, children|
            foreign_key ||= infer_foreign_key(parents, association_name)

            parents.each do |parent|
              # parent.relations(association_name).loaded!
              parent_identifier = parent.send(primary_key)
              relevant_children = children.detect { |child| child.send(foreign_key) == parent_identifier }
              parent.set_relation(association_name, relevant_children)
            end
          end

          instance_eval(&blk) if blk
        end
      end

      # Mongoid embeds_many sideload still needs to filter embedded records according to the scope !!
      # (Currently only works with no filtering )
      #
      # @param association_name [Symbol]
      # @param scope: nil [Mongoid::Criteria]
      # @param resource: nil [JsonapiCompliable::Resource]
      #
      # @return [void]
      def embeds_many(association_name, scope: nil, resource:, foreign_key: nil, primary_key: :id, &blk)
        # TODO : https://github.com/Startouf/MyJobGlasses/issues/1794
        child_scope = scope

        allow_sideload association_name, type: :embeds_many, resource: resource, foreign_key: foreign_key, primary_key: primary_key do
          scope do |parents|
            child_scope ||= infer_default_child_scope(parents, association_name)
            # No need to do anything more ! Embedded data are already loaded => no need to locate them
          end

          assign do |parents, _children|
            parents.each do |parent|
              # parent.embedded_relation returns a Mongoid::Criteria that can be merged with a root one
              # ie professional.ratings.merge(Rating.desc(:rating)) WORKS !!
              relevant_embedded_records = parent.send(association_name).merge(child_scope)
              parent.set_relation(association_name, relevant_embedded_records)
            end
          end

          instance_eval(&blk) if blk
        end
      end

      # @Override implementation for Mongoid, should be pretty similar to AR
      # @example
      # conversation has_many :messages, message belongs_to :conversation
      # => parent = message, child = conversation
      # => foreign_key :conversation_id
      # =>
      # parent = conversation
      # child = message
      def belongs_to(association_name, scope: nil, resource:, foreign_key: nil, primary_key: :id, &blk)
        # Fetch initial scope
        child_scope = scope

        allow_sideload association_name, type: :belongs_to, resource: resource, foreign_key: foreign_key, primary_key: primary_key do
          scope do |parents| # parents = conversations_criteria
            foreign_key ||= infer_foreign_key(parents, association_name)
            child_scope ||= infer_default_child_scope(parents, association_name)

            children_ids = parents.map { |parent| parent.send(foreign_key) }
            child_scope.in(primary_key => children_ids.uniq.compact)
          end

          assign do |parents, children|
            foreign_key ||= infer_foreign_key(parents, association_name)

            parents.each do |parent|
              parent_identifier = parent.send(foreign_key)
              relevant_child = children.find { |c| c.send(primary_key) == parent_identifier }
              parent.set_relation(association_name, relevant_child)
            end
          end
        end
      end

      # HABTM in Mongoid stores the keys locally in an array
      # Memory : model.association_ids #=> [BSON::ObjectID('cafebabe'), BSON::ObjectID('badf00d'), ...]
      # Serial : model.association_ids #=> ['cafebabe', 'badf00d', ... }
      #
      # @param association_name [Symbol] Association name
      # @param scope: nil [type] [description]
      # @param resource: [type] [description]
      #
      # @param foreign_key: [type] Accessor to the array of foreign keys
      # @param primary_key: :id [Symbol] Primary key of the model to be found
      # @param &blk [type] [description]
      #
      # @return [type] [description]
      def has_and_belongs_to_many(association_name, scope: nil, resource:, foreign_key: nil, foreign_keys_key: nil, primary_key: :id, &blk)
        child_scope = scope
        foreign_keys_key ||= "#{association_name.to_s.singularize}_ids"
        foreign_key = :id # compatibility reasons

        allow_sideload association_name, type: :habtm, resource: resource, foreign_key: foreign_key, primary_key: primary_key do
          scope do |parents|
            # TODO : merge selectors with ORs (???)
            child_scope ||= infer_default_child_scope(parents, association_name)
            sideload_ids = parents.flat_map { |p| p.send(foreign_keys_key) }.uniq.compact
            child_scope.in(id: sideload_ids)
          end

          assign do |parents, foreign_objects|
            parents.each do |local_object|
              # Assign foreign objects if their ID is in the ID list of the parent
              local_keys = local_object.send("#{association_name.to_s.singularize}_ids")
              relevant_foreign_objects = foreign_objects.select do |foreign_object|
                local_keys.include?(foreign_object.send(foreign_key))
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
            foreign_key = config[:foreign_key] || :"#{association_name}_id"

            allow_sideload type, primary_key: primary_key, foreign_key: foreign_key, type: :belongs_to, resource: config[:resource] do
              scope do |parents|
                parent_ids = parents.map { |parent| parent.send(foreign_key) }
                parent_ids.compact!
                parent_ids.uniq!
                config[:scope].call.in(primary_key => parent_ids)
              end

              assign do |parents, children|
                parents.each do |parent|
                  parent_identifier = parent.send(foreign_key)
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
