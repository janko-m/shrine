# frozen_string_literal: true

require "roda"

require "base64"
require "json"

class Shrine
  module Plugins
    # The `download_endpoint` plugin provides a Rack endpoint for downloading
    # uploaded files from specified storages. This can be useful when files
    # from your storages aren't accessible over URL (e.g. database storages) or
    # if you want to authenticate your downloads. It requires the [Roda] gem.
    #
    #     plugin :download_endpoint, storages: [:store], prefix: "attachments"
    #
    # After loading the plugin the endpoint should be mounted on the specified
    # prefix:
    #
    #     # config.ru (Rack)
    #     map "/attachments" do
    #       run Shrine.download_endpoint
    #     end
    #
    #     # OR
    #
    #     # config/routes.rb (Rails)
    #     Rails.application.routes.draw do
    #       mount Shrine.download_endpoint => "/attachments"
    #     end
    #
    # Now all stored files can be downloaded through the endpoint, and the
    # endpoint will efficiently stream the file from the storage when the
    # storage supports it. `UploadedFile#url` will automatically return the URL
    # to the endpoint for files uploaded to specified storages:
    #
    #     user.avatar.url #=> "/attachments/eyJpZCI6ImFkdzlyeTM5ODJpandoYWla"
    #
    # :storages
    # :  An array of storage keys for which `UploadedFile#url` should generate
    #    download endpoint URLs.
    #
    # :prefix
    # :  The location where the download endpoint was mounted. If it was
    #    mounted at the root level, this should be set to nil.
    #
    # :host
    # :  The host that you want the download URLs to use (e.g. your app's domain
    #    name or a CDN). By default URLs are relative.
    #
    # :disposition
    # :  Can be set to "attachment" if you want that the user is always
    #    prompted to download the file when visiting the download URL.
    #    The default is "inline".
    #
    # Note that streaming the file through your app might impact the request
    # throughput of your app, depending on which web server is used. In any
    # case, it's recommended to use some kind of cache in front of the web
    # server.
    #
    # If you want to authenticate the downloads, it's recommended you use the
    # `rack_response` plugin directly. With it you can return file responses
    # from inside your router/controller.
    #
    # [Roda]: https://github.com/jeremyevans/roda
    module DownloadEndpoint
      def self.load_dependencies(uploader, opts = {})
        uploader.plugin :rack_response
      end

      def self.configure(uploader, opts = {})
        uploader.opts[:download_endpoint_storages] = opts.fetch(:storages, uploader.opts[:download_endpoint_storages])
        uploader.opts[:download_endpoint_prefix] = opts.fetch(:prefix, uploader.opts[:download_endpoint_prefix])
        uploader.opts[:download_endpoint_disposition] = opts.fetch(:disposition, uploader.opts.fetch(:download_endpoint_disposition, "inline"))
        uploader.opts[:download_endpoint_host] = opts.fetch(:host, uploader.opts[:download_endpoint_host])

        raise Error, "The :storages option is required for download_endpoint plugin" if uploader.opts[:download_endpoint_storages].nil?

        uploader.assign_download_endpoint(App) unless uploader.const_defined?(:DownloadEndpoint)
      end

      module ClassMethods
        # Assigns the subclass a copy of the download endpoint class.
        def inherited(subclass)
          super
          subclass.assign_download_endpoint(@download_endpoint)
        end

        # Returns the Rack application that retrieves requested files.
        def download_endpoint
          @download_endpoint
        end

        # Assigns the subclassed endpoint as the `DownloadEndpoint` constant.
        def assign_download_endpoint(klass)
          endpoint_class = Class.new(klass)
          endpoint_class.opts[:shrine_class] = self
          endpoint_class.opts[:disposition]  = opts[:download_endpoint_disposition]

          @download_endpoint = endpoint_class

          const_set(:DownloadEndpoint, endpoint_class)
          deprecate_constant(:DownloadEndpoint) if RUBY_VERSION > "2.3"
        end

        def download_endpoint_serializer
          @download_endpoint_serializer ||= Serializer.new
        end
      end

      module FileMethods
        # Constructs the URL from the optional host, prefix, storage key and
        # uploaded file's id. For other uploaded files that aren't in the list
        # of storages it just returns their original URL.
        def url(**options)
          if shrine_class.opts[:download_endpoint_storages].include?(storage_key.to_sym)
            download_url
          else
            super
          end
        end

        private

        def download_url
          [download_host, *download_prefix, download_identifier].join("/")
        end

        # Generates URL-safe identifier from data, filtering only a subset of
        # metadata that the endpoint needs to prevent the URL from being too
        # long.
        def download_identifier
          semantical_metadata = metadata.select { |name, _| %w[filename size mime_type].include?(name) }
          download_serializer.dump(data.merge("metadata" => semantical_metadata))
        end

        def download_serializer
          shrine_class.download_endpoint_serializer
        end

        def download_host
          shrine_class.opts[:download_endpoint_host]
        end

        def download_prefix
          shrine_class.opts[:download_endpoint_prefix]
        end
      end

      # Routes incoming requests. It first asserts that the storage is existent
      # and allowed. Afterwards it proceeds with the file download using
      # streaming.
      class App < Roda
        route do |r|
          # handle legacy ":storage/:id" URLs
          r.on storage_names do |storage_name|
            r.get /(.*)/ do |id|
              data = { "id" => id, "storage" => storage_name, "metadata" => {} }
              stream_file(data)
            end
          end

          r.get /(.*)/ do |identifier|
            data = serializer.load(identifier)
            stream_file(data)
          end
        end

        private

        def stream_file(data)
          uploaded_file = get_uploaded_file(data)
          range         = env["HTTP_RANGE"]

          status, headers, body = uploaded_file.to_rack_response(disposition: disposition, range: range)
          headers["Cache-Control"] = "max-age=#{365*24*60*60}" # cache for a year

          request.halt [status, headers, body]
        end

        # Returns a Shrine::UploadedFile, or returns 404 if file doesn't exist.
        def get_uploaded_file(data)
          uploaded_file = shrine_class.uploaded_file(data)
          not_found! unless uploaded_file.exists?
          uploaded_file
        rescue Shrine::Error
          not_found!
        end

        def not_found!
          error!(404, "File Not Found")
        end

        # Halts the request with the error message.
        def error!(status, message)
          response.status = status
          response["Content-Type"] = "text/plain"
          response.write(message)
          request.halt
        end

        def storage_names
          shrine_class.storages.keys.map(&:to_s)
        end

        def serializer
          shrine_class.download_endpoint_serializer
        end

        def disposition
          opts[:disposition]
        end

        def shrine_class
          opts[:shrine_class]
        end
      end

      class Serializer
        def dump(data)
          base64_encode(json_encode(data))
        end

        def load(data)
          json_decode(base64_decode(data))
        end

        private

        def json_encode(data)
          JSON.generate(data)
        end

        def base64_encode(data)
          Base64.urlsafe_encode64(data)
        end

        def base64_decode(data)
          Base64.urlsafe_decode64(data)
        end

        def json_decode(data)
          JSON.parse(data)
        end
      end
    end

    register_plugin(:download_endpoint, DownloadEndpoint)
  end
end
