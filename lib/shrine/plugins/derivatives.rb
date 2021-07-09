# frozen_string_literal: true

class Shrine
  module Plugins
    # Documentation can be found on https://shrinerb.com/docs/plugins/derivatives
    module Derivatives
      LOG_SUBSCRIBER = -> (event) do
        Shrine.logger.info "Derivatives (#{event.duration}ms) – #{{
          processor:         event[:processor],
          processor_options: event[:processor_options],
          uploader:          event[:uploader],
        }.inspect}"
      end

      def self.load_dependencies(uploader, versions_compatibility: false, **)
        uploader.plugin :default_url

        AttacherMethods.prepend(VersionsCompatibility) if versions_compatibility
      end

      def self.configure(uploader, log_subscriber: LOG_SUBSCRIBER, **opts)
        uploader.opts[:derivatives] ||= { processors: {}, processor_settings: {}, storage: proc { store_key } }
        uploader.opts[:derivatives].merge!(opts)

        # instrumentation plugin integration
        uploader.subscribe(:derivatives, &log_subscriber) if uploader.respond_to?(:subscribe)
      end

      module AttachmentMethods
        def define_entity_methods(name)
          super if defined?(super)

          define_method(:"#{name}_derivatives") do |*args|
            send(:"#{name}_attacher").get_derivatives(*args)
          end
        end

        def define_model_methods(name)
          super if defined?(super)

          define_method(:"#{name}_derivatives!") do |*args, **options|
            send(:"#{name}_attacher").create_derivatives(*args, **options)
          end
        end
      end

      module AttacherClassMethods
        # Registers a derivatives processor on the attacher class.
        #
        #     Attacher.derivatives_processor :thumbnails do |original|
        #       # ...
        #     end
        #
        # By default, Shrine will convert the source IO object into a file
        # before it's passed to the processor block. You can set `download:
        # false` to pass the source IO object to the processor block as is.
        #
        #     Attacher.derivatives_processor :thumbnails, download: false do |original|
        #       # ...
        #     end
        #
        # This can be useful if you'd like to defer or avoid a possibly
        # expensive download operation for processor logic that does not
        # require it.
        def derivatives_processor(name = :default, download: true, &block)
          if block
            shrine_class.derivatives_options[:processors][name.to_sym] = block
            shrine_class.derivatives_options[:processor_settings][name.to_sym] = { download: download }
          else
            shrine_class.derivatives_options[:processors].fetch(name.to_sym) do
              fail Error, "derivatives processor #{name.inspect} not registered" unless name == :default
            end
          end
        end
        alias derivatives derivatives_processor

        # Returns settings for the given derivatives processor.
        #
        #     Attacher.derivatives_processor_settings(:thumbnails) #=> { download: true }
        def derivatives_processor_settings(name)
          shrine_class.derivatives_options[:processor_settings][name.to_sym] || {}
        end

        # Specifies default storage to which derivatives will be uploaded.
        #
        #     Attacher.derivatives_storage :other_store
        #     # or
        #     Attacher.derivatives_storage do |name|
        #       if name == :thumbnail
        #         :thumbnail_store
        #       else
        #         :store
        #       end
        #     end
        def derivatives_storage(storage_key = nil, &block)
          if storage_key || block
            shrine_class.derivatives_options[:storage] = storage_key || block
          else
            shrine_class.derivatives_options[:storage]
          end
        end
      end

      module AttacherMethods
        attr_reader :derivatives

        # Adds the ability to accept derivatives.
        def initialize(derivatives: {}, **options)
          super(**options)

          @derivatives       = derivatives
          @derivatives_mutex = Mutex.new
        end

        # Convenience method for accessing derivatives.
        #
        #     photo.image_derivatives[:thumb] #=> #<Shrine::UploadedFile>
        #     # can be shortened to
        #     photo.image(:thumb) #=> #<Shrine::UploadedFile>
        def get(*path)
          return super if path.empty?

          get_derivatives(*path)
        end

        # Convenience method for accessing derivatives.
        #
        #     photo.image_derivatives.dig(:thumbnails, :large)
        #     # can be shortened to
        #     photo.image_derivatives(:thumbnails, :large)
        def get_derivatives(*path)
          return derivatives if path.empty?

          path = derivative_path(path)

          derivatives.dig(*path)
        end

        # Allows generating a URL to the derivative by passing the derivative
        # name.
        #
        #     attacher.add_derivatives(thumb: thumb)
        #     attacher.url(:thumb) #=> "https://example.org/thumb.jpg"
        def url(*path, **options)
          return super if path.empty?

          path = derivative_path(path)

          url   = derivatives.dig(*path)&.url(**options)
          url ||= default_url(**options, derivative: path)
          url
        end

        # In addition to promoting the main file, also promotes any cached
        # derivatives. This is useful when these derivatives are being created
        # as part of a direct upload.
        #
        #     attacher.assign(io)
        #     attacher.add_derivative(:thumb, file, storage: :cache)
        #     attacher.promote
        #     attacher.stored?(attacher.derivatives[:thumb]) #=> true
        def promote(**options)
          super
          promote_derivatives
          create_derivatives if create_derivatives_on_promote?
        end

        # Uploads any cached derivatives to permanent storage.
        def promote_derivatives(**options)
          stored_derivatives = map_derivative(derivatives) do |path, derivative|
            if cached?(derivative)
              upload_derivative(path, derivative, **options)
            else
              derivative
            end
          end

          set_derivatives(stored_derivatives) unless derivatives == stored_derivatives
        end

        # In addition to deleting the main file it also deletes any derivatives.
        #
        #     attacher.add_derivatives(thumb: thumb)
        #     attacher.derivatives[:thumb].exists? #=> true
        #     attacher.destroy
        #     attacher.derivatives[:thumb].exists? #=> false
        def destroy
          super
          delete_derivatives
        end

        # Calls processor and adds returned derivatives.
        #
        #     Attacher.derivatives_processor :my_processor do |original|
        #       # ...
        #     end
        #
        #     attacher.create_derivatives(:my_processor)
        def create_derivatives(*args, storage: nil, **options)
          files = process_derivatives(*args, **options)
          add_derivatives(files, storage: storage)
        end

        # Uploads given hash of files and adds uploaded files to the
        # derivatives hash.
        #
        #     attacher.derivatives #=>
        #     # {
        #     #   thumb: #<Shrine::UploadedFile>,
        #     # }
        #     attacher.add_derivatives(cropped: cropped)
        #     attacher.derivatives #=>
        #     # {
        #     #   thumb: #<Shrine::UploadedFile>,
        #     #   cropped: #<Shrine::UploadedFile>,
        #     # }
        def add_derivatives(files, **options)
          new_derivatives = upload_derivatives(files, **options)
          merge_derivatives(new_derivatives)
          new_derivatives
        end

        # Uploads a given file and adds it to the derivatives hash.
        #
        #     attacher.derivatives #=>
        #     # {
        #     #   thumb: #<Shrine::UploadedFile>,
        #     # }
        #     attacher.add_derivative(:cropped, cropped)
        #     attacher.derivatives #=>
        #     # {
        #     #   thumb: #<Shrine::UploadedFile>,
        #     #   cropped: #<Shrine::UploadedFile>,
        #     # }
        def add_derivative(name, file, **options)
          add_derivatives({ name => file }, **options)
          derivatives[name]
        end

        # Uploads given hash of files.
        #
        #     hash = attacher.upload_derivatives(thumb: thumb)
        #     hash[:thumb] #=> #<Shrine::UploadedFile>
        def upload_derivatives(files, **options)
          map_derivative(files) do |path, file|
            upload_derivative(path, file, **options)
          end
        end

        # Uploads the given file and deletes it afterwards.
        #
        #     hash = attacher.upload_derivative(:thumb, thumb)
        #     hash[:thumb] #=> #<Shrine::UploadedFile>
        def upload_derivative(path, file, storage: nil, **options)
          path      = derivative_path(path)
          storage ||= derivative_storage(path)

          file.open    if file.is_a?(Tempfile)       # refresh file descriptor
          file.binmode if file.respond_to?(:binmode) # ensure binary mode

          upload(file, storage, derivative: path, delete: true, action: :derivatives, **options)
        end

        # Downloads the attached file and calls the specified processor.
        #
        #     Attacher.derivatives_processor :thumbnails do |original|
        #       processor = ImageProcessing::MiniMagick.source(original)
        #
        #       {
        #         small:  processor.resize_to_limit!(300, 300),
        #         medium: processor.resize_to_limit!(500, 500),
        #         large:  processor.resize_to_limit!(800, 800),
        #       }
        #     end
        #
        #     attacher.process_derivatives(:thumbnails)
        #     #=> { small: #<File:...>, medium: #<File:...>, large: #<File:...> }
        def process_derivatives(processor_name = :default, source = nil, **options)
          # handle receiving only source file without a processor
          unless processor_name.respond_to?(:to_sym)
            source         = processor_name
            processor_name = :default
          end

          source ||= file!

          processor_settings = self.class.derivatives_processor_settings(processor_name) || {}

          if processor_settings[:download]
            shrine_class.with_file(source) do |file|
              _process_derivatives(processor_name, file, **options)
            end
          else
            _process_derivatives(processor_name, source, **options)
          end
        end

        # Deep merges given uploaded derivatives with current derivatives.
        #
        #     attacher.derivatives #=> { one: #<Shrine::UploadedFile> }
        #     attacher.merge_derivatives(two: uploaded_file)
        #     attacher.derivatives #=> { one: #<Shrine::UploadedFile>, two: #<Shrine::UploadedFile> }
        def merge_derivatives(new_derivatives)
          @derivatives_mutex.synchronize do
            merged_derivatives = deep_merge_derivatives(derivatives, new_derivatives)
            set_derivatives(merged_derivatives)
          end
        end

        # Removes derivatives with specified name from the derivatives hash.
        #
        #     attacher.derivatives
        #     #=> { one: #<Shrine::UploadedFile>, two: #<Shrine::UploadedFile>, three: #<Shrine::UploadedFile> }
        #
        #     attacher.remove_derivatives(:two, :three)
        #     #=> [#<Shrine::UploadedFile>, #<Shrine::UploadedFile>] (removed derivatives)
        #
        #     attacher.derivatives
        #     #=> { one: #<Shrine::UploadedFile> }
        #
        # Nested derivatives are also supported:
        #
        #     attacher.derivatives
        #     #=> { nested: { one: #<Shrine::UploadedFile>, two: #<Shrine::UploadedFile>, three: #<Shrine::UploadedFile> } }
        #
        #     attacher.remove_derivatives([:nested, :two], [:nested, :three])
        #     #=> [#<Shrine::UploadedFile>, #<Shrine::UploadedFile>] (removed derivatives)
        #
        #     attacher.derivatives
        #     #=> { nested: { one: #<Shrine::UploadedFile> } }
        #
        # The :delete option can be passed for deleting removed derivatives:
        #
        #     attacher.derivatives
        #     #=> { one: #<Shrine::UploadedFile>, two: #<Shrine::UploadedFile>, three: #<Shrine::UploadedFile> }
        #
        #     two, three = attacher.remove_derivatives(:two, :three, delete: true)
        #
        #     two.exists?   #=> false
        #     three.exists? #=> false
        def remove_derivatives(*paths, delete: false)
          removed_derivatives = paths.map do |path|
            path = Array(path)

            if path.one?
              derivatives.delete(path.first)
            else
              derivatives.dig(*path[0..-2]).delete(path[-1])
            end
          end

          set_derivatives derivatives

          delete_derivatives(removed_derivatives) if delete

          removed_derivatives
        end

        # Removes derivative with specified name from the derivatives hash.
        #
        #     attacher.derivatives #=> { one: #<Shrine::UploadedFile>, two: #<Shrine::UploadedFile> }
        #     attacher.remove_derivative(:one) #=> #<Shrine::UploadedFile> (removed derivative)
        #     attacher.derivatives #=> { two: #<Shrine::UploadedFile> }
        #
        # Nested derivatives are also supported:
        #
        #     attacher.derivatives #=> { nested: { one: #<Shrine::UploadedFile>, two: #<Shrine::UploadedFile> } }
        #     attacher.remove_derivative([:nested, :one]) #=> #<Shrine::UploadedFile> (removed derivative)
        #     attacher.derivatives #=> { nested: { one: #<Shrine::UploadedFile> } }
        #
        # The :delete option can be passed for deleting removed derivative:
        #
        #     attacher.derivatives #=> { one: #<Shrine::UploadedFile>, two: #<Shrine::UploadedFile> }
        #     derivative = attacher.remove_derivatives(:two, delete: true)
        #     derivative.exists? #=> false
        def remove_derivative(path, **options)
          remove_derivatives(path, **options).first
        end

        # Deletes given hash of uploaded files.
        #
        #     attacher.delete_derivatives(thumb: uploaded_file)
        #     uploaded_file.exists? #=> false
        def delete_derivatives(derivatives = self.derivatives)
          map_derivative(derivatives) { |_, derivative| derivative.delete }
        end

        # Sets the given hash of uploaded files as derivatives.
        #
        #     attacher.set_derivatives(thumb: uploaded_file)
        #     attacher.derivatives #=> { thumb: #<Shrine::UploadedFile> }
        def set_derivatives(derivatives)
          self.derivatives = derivatives
          set file # trigger model write
          derivatives
        end

        # Adds derivative data into the hash.
        #
        #     attacher.attach(io)
        #     attacher.add_derivatives(thumb: thumb)
        #     attacher.data
        #     #=>
        #     # {
        #     #   "id" => "...",
        #     #   "storage" => "store",
        #     #   "metadata" => { ... },
        #     #   "derivatives" => {
        #     #     "thumb" => {
        #     #       "id" => "...",
        #     #       "storage" => "store",
        #     #       "metadata" => { ... },
        #     #     }
        #     #   }
        #     # }
        def data
          result = super

          if derivatives.any?
            result ||= {}
            result["derivatives"] = map_derivative(derivatives, transform_keys: :to_s) do |_, derivative|
              derivative.data
            end
          end

          result
        end

        # Loads derivatives from data generated by `Attacher#data`.
        #
        #     attacher.load_data({
        #       "id" => "...",
        #       "storage" => "store",
        #       "metadata" => { ... },
        #       "derivatives" => {
        #         "thumb" => {
        #           "id" => "...",
        #           "storage" => "store",
        #           "metadata" => { ... },
        #         }
        #       }
        #     })
        #     attacher.file        #=> #<Shrine::UploadedFile>
        #     attacher.derivatives #=> { thumb: #<Shrine::UploadedFile> }
        def load_data(data)
          data ||= {}
          data   = data.dup

          derivatives_data = data.delete("derivatives") || data.delete(:derivatives) || {}
          @derivatives     = shrine_class.derivatives(derivatives_data)

          data = nil if data.empty?

          super(data)
        end

        # Clears derivatives when attachment changes.
        #
        #     attacher.derivatives #=> { thumb: #<Shrine::UploadedFile> }
        #     attacher.change(file)
        #     attacher.derivatives #=> {}
        def change(*)
          result = super
          set_derivatives({})
          result
        end

        # Sets a hash of derivatives.
        #
        #     attacher.derivatives = { thumb: Shrine.uploaded_file(...) }
        #     attacher.derivatives #=> { thumb: #<Shrine::UploadedFile ...> }
        def derivatives=(derivatives)
          unless derivatives.is_a?(Hash)
            fail ArgumentError, "expected derivatives to be a Hash, got #{derivatives.inspect}"
          end

          @derivatives = derivatives
        end

        # Iterates through nested derivatives and maps results.
        #
        #     attacher.map_derivative(derivatives) { |path, file| ... }
        def map_derivative(derivatives, **options, &block)
          shrine_class.map_derivative(derivatives, **options, &block)
        end

        # Support for proper marshalling
        #
        # It's impossible to marshal any models with this plugin
        # as we can't marshal `Mutex` reliably.
        def marshal_dump
          instance_variables.reject do |name|
            name == :@derivatives_mutex
          end.map do |name|
            [name, instance_variable_get(name)]
          end
        end

        # Load marshalled instance
        #
        # We reload all instance variables, and re-create
        # mutex. Otherwise the object won't function properly
        def marshal_load(instance_variables)
          instance_variables.each do |name, value|
            instance_variable_set(name, value)
          end

          @derivatives_mutex = Mutex.new
        end

        private

        # Calls the derivatives processor with the source file and options.
        def _process_derivatives(processor_name, source, **options)
          processor = self.class.derivatives_processor(processor_name)

          return {} unless processor

          result = instrument_derivatives(processor_name, source, options) do
            instance_exec(source, **options, &processor)
          end

          unless result.is_a?(Hash)
            fail Error, "expected derivatives processor #{processor_name.inspect} to return a Hash, got #{result.inspect}"
          end

          result
        end

        # Sends a `derivatives.shrine` event for instrumentation plugin.
        def instrument_derivatives(processor_name, source, processor_options, &block)
          return yield unless shrine_class.respond_to?(:instrument)

          shrine_class.instrument(:derivatives, {
            processor:         processor_name,
            processor_options: processor_options,
            io:                source,
            attacher:          self,
          }, &block)
        end

        # Returns symbolized array or single key.
        def derivative_path(path)
          path = Array(path).map { |key| key.is_a?(String) ? key.to_sym : key }
          path = path.first if path.one?
          path
        end

        # Storage to which derivatives will be uploaded to by default.
        def derivative_storage(path)
          storage = self.class.derivatives_storage
          storage = instance_exec(path, &storage) if storage.respond_to?(:call)
          storage
        end

        # Deep merge nested hashes/arrays.
        def deep_merge_derivatives(o1, o2)
          if o1.is_a?(Hash) && o2.is_a?(Hash)
            o1.merge(o2) { |_, v1, v2| deep_merge_derivatives(v1, v2) }
          elsif o1.is_a?(Array) && o2.is_a?(Array)
            o1 + o2
          else
            o2
          end
        end

        # Whether to automatically create derivatives on promotion
        def create_derivatives_on_promote?
          shrine_class.derivatives_options[:create_on_promote]
        end
      end

      module ClassMethods
        # Converts data into a Hash of derivatives.
        #
        #     Shrine.derivatives('{"thumb":{"id":"foo","storage":"store","metadata":{}}}')
        #     #=> { thumb: #<Shrine::UploadedFile id="foo" storage=:store metadata={}> }
        #
        #     Shrine.derivatives({ "thumb" => { "id" => "foo", "storage" => "store", "metadata" => {} } })
        #     #=> { thumb: #<Shrine::UploadedFile id="foo" storage=:store metadata={}> }
        #
        #     Shrine.derivatives({ thumb: { id: "foo", storage: "store", metadata: {} } })
        #     #=> { thumb: #<Shrine::UploadedFile id="foo" storage=:store metadata={}> }
        def derivatives(object)
          if object.is_a?(String)
            derivatives JSON.parse(object)
          elsif object.is_a?(Hash) || object.is_a?(Array)
            map_derivative(
              object,
              transform_keys: :to_sym,
              leaf: -> (value) { value.is_a?(Hash) && (value["id"] || value[:id]).is_a?(String) },
            ) { |_, value| uploaded_file(value) }
          else
            fail ArgumentError, "cannot convert #{object.inspect} to derivatives"
          end
        end

        # Iterates over a nested collection, yielding on each part of the path.
        # If the block returns a truthy value, that branch is terminated
        def map_derivative(object, path = [], transform_keys: :to_sym, leaf: nil, &block)
          return enum_for(__method__, object) unless block_given?

          if leaf && leaf.call(object)
            yield path, object
          elsif object.is_a?(Hash)
            object.inject({}) do |hash, (key, value)|
              key = key.send(transform_keys)

              hash.merge! key => map_derivative(
                value, [*path, key],
                transform_keys: transform_keys, leaf: leaf,
                &block
              )
            end
          elsif object.is_a?(Array)
            object.map.with_index do |value, idx|
              map_derivative(
                value, [*path, idx],
                transform_keys: transform_keys, leaf: leaf,
                &block
              )
            end
          else
            yield path, object
          end
        end

        # Returns derivatives plugin options.
        def derivatives_options
          opts[:derivatives]
        end
      end

      module FileMethods
        def [](*keys)
          if keys.any? { |key| key.is_a?(Symbol) }
            fail Error, "Shrine::UploadedFile#[] doesn't accept symbol metadata names. Did you happen to call `record.attachment[:derivative_name]` when you meant to call `record.attachment(:derivative_name)`?"
          else
            super
          end
        end
      end

      # Adds compatibility with how the versions plugin stores processed files.
      module VersionsCompatibility
        def load_data(data)
          return super if data.nil?
          return super if data["derivatives"] || data[:derivatives]
          return super if (data["id"] || data[:id]).is_a?(String)

          data     = data.dup
          original = data.delete("original") || data.delete(:original) || {}

          super original.merge("derivatives" => data)
        end
      end
    end

    register_plugin(:derivatives, Derivatives)
  end
end
