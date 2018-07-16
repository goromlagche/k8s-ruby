require 'securerandom'

module Pharos
  module Kube
    class Stack
      include Logging

      LABEL = 'pharos.kontena.io/stack'
      CHECKSUM_ANNOTATION = 'pharos.kontena.io/stack-checksum'
      PRUNE_IGNORE = [
        'v1:ComponentStatus', # apiserver ignores GET /v1/componentstatuses?labelSelector=... and returns all resources
        'v1:Endpoints', # inherits stack label from service, but not checksum annotation
      ]

      def self.load(path, name: nil, **options)
        resources = Pharos::Kube::Resource.from_files(path)
        new(name || File.basename(path), resources, **options)
      end

      attr_reader :name, :resources

      def initialize(name, resources, debug: false)
        @name = name
        @resources = resources

        logger! progname: name, debug: debug
      end

      def checksum
        @checksum ||= SecureRandom.hex(16)
      end

      # @param resource [Pharos::Kube::Resource] to apply
      # @param base_resource [Pharos::Kube::Resource] preserve existing attributes from base resource
      # @return [Pharos::Kube::Resource]
      def prepare_resource(resource, base_resource: nil)
        if base_resource
          resource = base_resource.merge(resource)
        end

        # add stack metadata
        resource.merge(metadata: {
          labels: { LABEL => name },
          annotations: { CHECKSUM_ANNOTATION => checksum },
        })
      end

      # @return [Array<Pharos::Kube::Resource>]
      def apply(client, prune: true)
        server_resources = client.get_resources(resources)

        resources.zip(server_resources).map do |resource, server_resource|
          if server_resource
            logger.info "Update resource #{resource.apiVersion}:#{resource.kind}/#{resource.metadata.name} in namespace #{resource.metadata.namespace}"
            client.update_resource(prepare_resource(resource, base_resource: server_resource))
          else
            logger.info "Create resource #{resource.apiVersion}:#{resource.kind}/#{resource.metadata.name} in namespace #{resource.metadata.namespace}"
            client.create_resource(prepare_resource(resource))
          end
        end

        prune(client, checksum: checksum) if prune
      end

      # Delete all stack resources that were not applied
      def prune(client, checksum: )
        client.apis(prefetch_resources: true).each do |api|
          logger.debug { "List resources in #{api.api_version}..."}

          api.list_resources(labelSelector: {LABEL => name}).each do |resource|
            next if PRUNE_IGNORE.include? "#{resource.apiVersion}:#{resource.kind}"

            resource_label = resource.metadata.labels ? resource.metadata.labels[LABEL] : nil
            resource_checksum = resource.metadata.annotations ? resource.metadata.annotations[CHECKSUM_ANNOTATION] : nil

            logger.debug { "List resource #{resource.apiVersion}:#{resource.kind}/#{resource.metadata.name} in namespace #{resource.metadata.namespace} with checksum=#{resource_checksum}" }

            if resource_label != name
              # apiserver did not respect labelSelector
            elsif checksum && resource_checksum == checksum
              # resource is up-to-date
            else
              logger.info "Delete resource #{resource.apiVersion}:#{resource.kind}/#{resource.metadata.name} in namespace #{resource.metadata.namespace}"
              client.delete_resource(resource)
            end
          end
        end
      end

      # Delete all stack resources
      def delete(client)
        prune(client, checksum: nil)
      end
    end
  end
end
