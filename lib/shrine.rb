require "shrine/version"

require "securerandom"
require "json"

class Shrine
  class Error < StandardError; end

  # Raised when a file was not a valid IO.
  class InvalidFile < Error
    def initialize(io, missing_methods)
      @io, @missing_methods = io, missing_methods
    end

    def message
      "#{@io.inspect} is not a valid IO object (it doesn't respond to #{missing_methods_string})"
    end

    private

    def missing_methods_string
      @missing_methods.map { |m, args| "##{m}" }.join(", ")
    end
  end

  # Methods which an object has to respond to in order to be considered
  # an IO object.  Keys are method names, and values are arguments.
  IO_METHODS = {
    :read   => [:length, :outbuf],
    :eof?   => [],
    :rewind => [],
    :size   => [],
    :close  => [],
  }

  # Core class that represents a file uploaded to a storage.  The instance
  # methods for this class are added by Shrine::Plugins::Base::FileMethods, the
  # class methods are added by Shrine::Plugins::Base::FileClassMethods.
  class UploadedFile
    @shrine_class = ::Shrine
  end

  # Core class which generates attachment-specific modules that are included in
  # model classes.  The instance methods for this class are added by
  # Shrine::Plugins::Base::AttachmentMethods, the class methods are added by
  # Shrine::Plugins::Base::AttachmentClassMethods.
  class Attachment < Module
    @shrine_class = ::Shrine
  end

  # Core class which handles attaching files on records.  The instance methods
  # for this class are added by Shrine::Plugins::Base::AttacherMethods, the
  # class methods are added by Shrine::Plugins::Base::AttacherClassMethods.
  class Attacher
    @shrine_class = ::Shrine
  end

  @opts = {}
  @storages = {}

  # Module in which all Shrine plugins should be stored. Also contains logic
  # for registering and loading plugins.
  module Plugins
    @plugins = {}

    # If the registered plugin already exists, use it.  Otherwise, require it
    # and return it.  This raises a LoadError if such a plugin doesn't exist,
    # or a Shrine::Error if it exists but it does not register itself
    # correctly.
    def self.load_plugin(name)
      unless plugin = @plugins[name]
        require "shrine/plugins/#{name}"
        raise Error, "plugin #{name} did not register itself correctly in Shrine::Plugins" unless plugin = @plugins[name]
      end
      plugin
    end

    # Register the given plugin with Shrine, so that it can be loaded using
    # `Shrine.plugin` with a symbol.  Should be used by plugin files. Example:
    #
    #     Shrine::Plugins.register_plugin(:plugin_name, PluginModule)
    def self.register_plugin(name, mod)
      @plugins[name] = mod
    end

    # The base plugin for Shrine, implementing all default functionality.
    # Methods are put into a plugin so future plugins can easily override
    # them and call `super` to get the default behavior.
    module Base
      module ClassMethods
        # Generic options for this class, plugins store their options here.
        attr_reader :opts

        # A hash of storages and their symbol identifiers.
        attr_accessor :storages

        # When inheriting Shrine, copy the instance variables into the subclass,
        # and setup the subclasses for core classes.
        def inherited(subclass)
          subclass.instance_variable_set(:@opts, opts.dup)
          subclass.opts.each do |key, value|
            if value.is_a?(Enumerable) && !value.frozen?
              subclass.opts[key] = value.dup
            end
          end
          subclass.instance_variable_set(:@storages, storages.dup)

          file_class = Class.new(self::UploadedFile)
          file_class.shrine_class = subclass
          subclass.const_set(:UploadedFile, file_class)

          attachment_class = Class.new(self::Attachment)
          attachment_class.shrine_class = subclass
          subclass.const_set(:Attachment, attachment_class)

          attacher_class = Class.new(self::Attacher)
          attacher_class.shrine_class = subclass
          subclass.const_set(:Attacher, attacher_class)
        end

        # Load a new plugin into the current class.  A plugin can be a module
        # which is used directly, or a symbol represented a registered plugin
        # which will be required and then used. Returns nil.
        #
        #     Shrine.plugin PluginModule
        #     Shrine.plugin :basic_authentication
        def plugin(plugin, *args, &block)
          plugin = Plugins.load_plugin(plugin) if plugin.is_a?(Symbol)
          plugin.load_dependencies(self, *args, &block) if plugin.respond_to?(:load_dependencies)
          self.include(plugin::InstanceMethods) if defined?(plugin::InstanceMethods)
          self.extend(plugin::ClassMethods) if defined?(plugin::ClassMethods)
          self::UploadedFile.include(plugin::FileMethods) if defined?(plugin::FileMethods)
          self::UploadedFile.extend(plugin::FileClassMethods) if defined?(plugin::FileClassMethods)
          self::Attachment.include(plugin::AttachmentMethods) if defined?(plugin::AttachmentMethods)
          self::Attachment.extend(plugin::AttachmentClassMethods) if defined?(plugin::AttachmentClassMethods)
          self::Attacher.include(plugin::AttacherMethods) if defined?(plugin::AttacherMethods)
          self::Attacher.extend(plugin::AttacherClassMethods) if defined?(plugin::AttacherClassMethods)
          plugin.configure(self, *args, &block) if plugin.respond_to?(:configure)
          nil
        end

        # Retrieves the storage specifies by the symbol/string, and raises an
        # appropriate error if the storage is missing
        def find_storage(name)
          storages.each { |key, value| return value if key.to_s == name.to_s }
          raise Error, "storage #{name.inspect} isn't registered on #{self}"
        end

        # Generates an instance of Shrine::Attachment to be included in the
        # model class.  Example:
        #
        #     class User
        #       include Shrine[:avatar] # alias for `Shrine.attachment(:avatar)`
        #     end
        def attachment(name)
          self::Attachment.new(name)
        end
        alias [] attachment

        # Instantiates a Shrine::UploadedFile from a hash, and optionally
        # yields the returned object.
        #
        #     data = {"storage" => "cache", "id" => "abc123.jpg", "metadata" => {}}
        #     Shrine.uploaded_file(data) #=> #<Shrine::UploadedFile>
        def uploaded_file(object, &block)
          case object
          when String
            warn "Giving a string to Shrine.uploaded_file is deprecated and won't be possible in Shrine 3. Use Attacher#uploaded_file instead."
            uploaded_file(JSON.parse(object), &block)
          when Hash
            uploaded_file(self::UploadedFile.new(object), &block)
          when self::UploadedFile
            object.tap { |f| yield(f) if block_given? }
          else
            raise Error, "cannot convert #{object.inspect} to a #{self}::UploadedFile"
          end
        end
      end

      module InstanceMethods
        # The symbol that identifies the storage.
        attr_reader :storage_key

        # The storage object identified by #storage_key.
        attr_reader :storage

        # Accepts a storage symbol registered in `Shrine.storages`.
        def initialize(storage_key)
          @storage = self.class.find_storage(storage_key)
          @storage_key = storage_key.to_sym
        end

        # The class-level options hash.  This should probably not be modified
        # at the instance level.
        def opts
          self.class.opts
        end

        # The main method for uploading files.  Takes in an IO object and an
        # optional context (used internally by Shrine::Attacher).  It calls
        # user-defined #process, and aferwards it calls #store.  The `io` is
        # closed after upload.
        def upload(io, context = {})
          io = processed(io, context) || io
          store(io, context)
        end

        # User is expected to perform processing inside of this method, and
        # return the processed files. Returning nil signals that no proccessing
        # has been done and that the original file should be used.
        #
        #     class ImageUploader < Shrine
        #       def process(io, context)
        #         case context[:action]
        #         when :cache
        #           # do processing
        #         when :store
        #           # do processing
        #         end
        #       end
        #     end
        def process(io, context = {})
        end

        # Uploads the file and returns an instance of Shrine::UploadedFile. By
        # default the location of the file is automatically generated by
        # \#generate_location, but you can pass in `:location` to upload to
        # a specific location.
        #
        #     uploader.store(io, location: "custom/location.jpg")
        def store(io, context = {})
          _store(io, context)
        end

        # Checks if the storage identified with this instance uploaded the
        # given file.
        def uploaded?(uploaded_file)
          uploaded_file.storage_key == storage_key.to_s
        end

        # Deletes the given uploaded file.
        def delete(uploaded_file, context = {})
          _delete(uploaded_file, context)
          uploaded_file
        end

        # Generates a unique location for the uploaded file, and preserves an
        # optional extension.
        def generate_location(io, context = {})
          extension   = ".#{io.extension}" if io.is_a?(UploadedFile) && io.extension
          extension ||= File.extname(extract_filename(io).to_s)
          basename  = generate_uid(io)

          basename + extension.to_s
        end

        # Extracts filename, size and MIME type from the file, which is later
        # accessible through `UploadedFile#metadata`. When the uploaded file
        # is later promoted, this metadata is simply copied over.
        def extract_metadata(io, context = {})
          {
            "filename"  => extract_filename(io),
            "size"      => extract_size(io),
            "mime_type" => extract_mime_type(io),
          }
        end

        private

        # Extracts the filename from the IO using some basic heuristics.
        def extract_filename(io)
          if io.respond_to?(:original_filename)
            io.original_filename
          elsif io.respond_to?(:path)
            File.basename(io.path)
          end
        end

        # Extracts the MIME type from the IO using some basic heuristics.
        def extract_mime_type(io)
          if io.respond_to?(:content_type)
            warn "The \"mime_type\" Shrine metadata field will be set from the \"Content-Type\" request header, which might not hold the actual MIME type of the file. It is recommended to load the determine_mime_type plugin which determines MIME type from file content." unless opts.key?(:mime_type_analyzer)
            io.content_type
          end
        end

        # Extracts the filesize from the IO.
        def extract_size(io)
          io.size
        end

        # Called by #store.  It first generates the location if it wasn't
        # already provided with the `:location` option.  Afterwards it extracts
        # the metadata, stores the file, and returns a Shrine::UploadedFile.
        def _store(io, context)
          _enforce_io(io)
          metadata = get_metadata(io, context)
          location = get_location(io, context.merge(metadata: metadata))

          put(io, context.merge(location: location, metadata: metadata))

          self.class.uploaded_file(
            "id"       => location,
            "storage"  => storage_key.to_s,
            "metadata" => metadata,
          )
        end

        # Removes the file. Called by #delete.
        def _delete(uploaded_file, context)
          remove(uploaded_file, context)
        end

        # Copies the file to the storage.
        def put(io, context)
          copy(io, context)
        end

        # Does the actual uploading, calling `#upload` on the storage.
        def copy(io, context)
          location = context[:location]
          metadata = context[:metadata]
          upload_options = context[:upload_options] || {}

          storage.upload(io, location, shrine_metadata: metadata, **upload_options)
        ensure
          io.close rescue nil
        end

        # Does the actual deletion, calls `UploadedFile#delete`.
        def remove(uploaded_file, context)
          uploaded_file.delete
        end

        # Calls #process and returns the processed files.
        def processed(io, context)
          process(io, context)
        end

        # Retrieves the location for the given io and context. First it looks
        # for the `:location` option, otherwise it calls #generate_location.
        def get_location(io, context)
          context[:location] || generate_location(io, context)
        end

        # Copies the metadata over from an UploadedFile or calls
        # #extract_metadata.
        def get_metadata(io, context)
          if io.is_a?(UploadedFile)
            io.metadata.dup
          else
            extract_metadata(io, context)
          end
        end

        # Checks if the object is a valid IO by checking that it responds to
        # `#read`, `#eof?`, `#rewind`, `#size` and `#close`, otherwise raises
        # Shrine::InvalidFile.
        def _enforce_io(io)
          missing_methods = IO_METHODS.select { |m, a| !io.respond_to?(m) }
          raise InvalidFile.new(io, missing_methods) if missing_methods.any?
        end

        # Generates a UID to use in location for uploaded files.
        def generate_uid(io)
          SecureRandom.hex
        end
      end

      module AttachmentClassMethods
        # Reference to the Shrine class related to this attachment class.
        attr_accessor :shrine_class

        # Since Attachment is anonymously subclassed when Shrine is subclassed,
        # and then assigned to a constant of the Shrine subclass, make inspect
        # reflect the likely name for the class.
        def inspect
          "#{shrine_class.inspect}::Attachment"
        end
      end

      module AttachmentMethods
        # Since Shrine::Attachment is a subclass of `Module`, this method
        # generates a module, which should be included in a model class.
        def initialize(name)
          @name = name

          # We store the attacher class so that it can be retrieved by the model
          # at the instance level when instantiating the attacher.  We use a
          # class variable because (a) it can be accessed from the instance
          # level without needing to create a class-level reader, and (b) we
          # want it to be inherited when subclassing the model
          class_variable_set(:"@@#{name}_attacher_class", shrine_class::Attacher)

          module_eval <<-RUBY, __FILE__, __LINE__ + 1
            def #{name}_attacher
              @#{name}_attacher ||= @@#{name}_attacher_class.new(self, :#{name})
            end

            def #{name}=(value)
              #{name}_attacher.assign(value)
            end

            def #{name}
              #{name}_attacher.get
            end

            def #{name}_url(*args)
              #{name}_attacher.url(*args)
            end
          RUBY
        end

        # Displays the attachment name.
        #
        #     Shrine[:avatar].to_s #=> "#<Shrine::Attachment(avatar)>"
        def to_s
          "#<#{self.class.inspect}(#{@name})>"
        end

        # Displays the attachment name.
        #
        #     Shrine[:avatar].inspect #=> "#<Shrine::Attachment(avatar)>"
        def inspect
          "#<#{self.class.inspect}(#{@name})>"
        end

        # Returns the Shrine class related to this attachment.
        def shrine_class
          self.class.shrine_class
        end
      end

      module AttacherClassMethods
        # Reference to the Shrine class related to this attacher class.
        attr_accessor :shrine_class

        # Since Attacher is anonymously subclassed when Shrine is subclassed,
        # and then assigned to a constant of the Shrine subclass, make inspect
        # reflect the likely name for the class.
        def inspect
          "#{shrine_class.inspect}::Attacher"
        end

        # Block that is executed in context of Shrine::Attacher during
        # validation.  Example:
        #
        #     Shrine::Attacher.validate do
        #       if get.size > 5*1024*1024
        #         errors << "is too big (max is 5 MB)"
        #       end
        #     end
        def validate(&block)
          shrine_class.opts[:validate] = block
        end
      end

      module AttacherMethods
        attr_reader :cache, :store, :context, :errors

        def initialize(record, name, cache: :cache, store: :store)
          @cache   = shrine_class.new(cache)
          @store   = shrine_class.new(store)
          @context = {record: record, name: name}
          @errors  = []
        end

        # Returns the model instance associated with the attacher.
        def record; context[:record]; end
        # Returns the attachment name associated with the attacher.
        def name;   context[:name];   end

        # Receives the attachment value from the form.  If it receives a JSON
        # string or a hash, it will assume this refrences an already cached
        # file (e.g. when it persisted after validation errors).
        # Otherwise it assumes that it's an IO object and caches it.
        def assign(value)
          if value.is_a?(String)
            return if value == "" || value == read || !cache.uploaded?(uploaded_file(value))
            assign_cached(uploaded_file(value))
          else
            uploaded_file = cache!(value, action: :cache) if value
            set(uploaded_file)
          end
        end

        # Assigns a Shrine::UploadedFile, runs validation and schedules the
        # old file for deletion.
        def set(uploaded_file)
          @old = get
          _set(uploaded_file)
          validate
        end

        # Runs the validations defined by `Attacher.validate`.
        def validate
          errors.clear
          instance_exec(&validate_block) if validate_block && get
        end

        # Returns true if a new file has been attached.
        def attached?
          instance_variable_defined?(:@old)
        end

        # Plugins can override this if they want something to be done on save.
        def save
        end

        # Deletes the old file and promotes the new one. Typically this should
        # be called after saving.
        def finalize
          replace
          remove_instance_variable(:@old)
          _promote(action: :store) if cached?
        end

        # Promotes the file.
        def _promote(uploaded_file = get, **options)
          promote(uploaded_file, **options)
        end

        # Uploads the cached file to store, and updates the record with the
        # stored file.
        def promote(uploaded_file = get, **options)
          stored_file = store!(uploaded_file, **options)
          result = swap(stored_file) or _delete(stored_file, action: :abort)
          result
        end

        # Calls #update, overriden in ORM plugins.
        def swap(uploaded_file)
          update(uploaded_file)
          uploaded_file if uploaded_file == get
        end

        # Deletes the attachment that was replaced, and is called after saving
        # by ORM integrations. If also removes `@old` so that #save and #finalize
        # don't get called for the current attachment anymore.
        def replace
          _delete(@old, action: :replace) if @old && !cache.uploaded?(@old)
        end

        # Deletes the attachment. Typically this should be called after
        # destroying a record.
        def destroy
          _delete(get, action: :destroy) if get && !cache.uploaded?(get)
        end

        # Deletes the uploaded file.
        def _delete(uploaded_file, **options)
          delete!(uploaded_file, **options)
        end

        # Returns the URL to the attached file (internally calls `#url` on the
        # storage), forwarding any URL options to the storage.
        def url(**options)
          get.url(**options) if read
        end

        # Returns true if attachment is present and cached.
        def cached?
          get && cache.uploaded?(get)
        end

        # Returns true if attachment is present and stored.
        def stored?
          get && store.uploaded?(get)
        end

        # Retrieves the uploaded file from the record column.
        def get
          uploaded_file(read) if read
        end

        # It reads from the record's `<attachment>_data` column.
        def read
          value = record.send(:"#{name}_data")
          value unless value.nil? || value.empty?
        end

        # Uploads the file to cache passing context.
        def cache!(io, **options)
          warn "Sending :phase to Shrine::Attacher#cache! is deprecated and will not be supported in Shrine 3. Use :action instead." if options[:phase]
          cache.upload(io, context.merge(_equalize_phase_and_action(options)))
        end

        # Uploads the file to store passing context.
        def store!(io, **options)
          warn "Sending :phase to Shrine::Attacher#store! is deprecated and will not be supported in Shrine 3. Use :action instead." if options[:phase]
          store.upload(io, context.merge(_equalize_phase_and_action(options)))
        end

        # Deletes the file passing context.
        def delete!(uploaded_file, **options)
          warn "Sending :phase to Shrine::Attacher#delete! is deprecated and will not be supported in Shrine 3. Use :action instead." if options[:phase]
          store.delete(uploaded_file, context.merge(_equalize_phase_and_action(options)))
        end

        # Delegates to `Shrine.uploaded_file`, additionally accepting uploaded
        # file as a JSON string.
        def uploaded_file(object, &block)
          if object.is_a?(String)
            uploaded_file(JSON.parse(object), &block)
          else
            shrine_class.uploaded_file(object, &block)
          end
        end

        # Returns the Shrine class related to this attacher.
        def shrine_class
          self.class.shrine_class
        end

        private

        # Assigns a cached file.
        def assign_cached(cached_file)
          set(cached_file)
        end

        # Sets and saves the uploaded file.
        def update(uploaded_file)
          _set(uploaded_file)
        end

        # The validation block provided by `Shrine.validate`.
        def validate_block
          shrine_class.opts[:validate]
        end

        # It dumps the UploadedFile to JSON and writes the result to the column.
        def _set(uploaded_file)
          write(uploaded_file ? uploaded_file.to_json : nil)
        end

        # It writes to record's `<attachment>_data` column.
        def write(value)
          record.send(:"#{name}_data=", value)
        end

        # Temporary method used for transitioning from :phase to :action.
        def _equalize_phase_and_action(options)
          options[:phase]  = options[:action] if options.key?(:action)
          options[:action] = options[:phase] if options.key?(:phase)
          options
        end
      end

      module FileClassMethods
        # Reference to the Shrine class related to this uploaded file class.
        attr_accessor :shrine_class

        # Since UploadedFile is anonymously subclassed when Shrine is subclassed,
        # and then assigned to a constant of the Shrine subclass, make inspect
        # reflect the likely name for the class.
        def inspect
          "#{shrine_class.inspect}::UploadedFile"
        end
      end

      module FileMethods
        # The entire data hash which identifies this uploaded file.
        attr_reader :data

        def initialize(data)
          @data = data
          @data["metadata"] ||= {}
          storage # ensure storage exists
        end

        # The ID of the uploaded file, which holds the location of the actual
        # file on the storage
        def id
          @data.fetch("id")
        end

        # The storage key as a string.
        def storage_key
          @data.fetch("storage")
        end

        # A hash of metadata.
        def metadata
          @data.fetch("metadata")
        end

        # The filename that was extracted from the original file.
        def original_filename
          metadata["filename"]
        end

        # The extension derived from #id if present, otherwise from
        # #original_filename.
        def extension
          File.extname(id)[1..-1] || File.extname(original_filename.to_s)[1..-1]
        end

        # The filesize of the original file.
        def size
          (@io && @io.size) || (metadata["size"] && Integer(metadata["size"]))
        end

        # The MIME type of the original file.
        def mime_type
          metadata["mime_type"]
        end
        alias content_type mime_type

        # Opens the underlying IO for reading and yields it to the block,
        # closing it after the block finishes. Use #to_io for opening without a
        # block.
        #
        #     uploaded_file.open do |io|
        #       # ...
        #     end
        def open
          @io = storage.open(id)
          yield @io
        ensure
          @io.close if @io
          @io = nil
        end

        # Calls `#download` on the storage if it is implemented, otherwise
        # streams the underlying IO to a Tempfile.
        def download
          if storage.respond_to?(:download)
            storage.download(id)
          else
            tempfile = Tempfile.new(["shrine", File.extname(id)], binmode: true)
            open { |io| IO.copy_stream(io, tempfile.path) }
            tempfile.tap(&:open)
          end
        end

        # Part of Shrine::UploadedFile's complying to the IO interface.  It
        # delegates to the internally downloaded file.
        def read(*args)
          io.read(*args)
        end

        # Part of Shrine::UploadedFile's complying to the IO interface.  It
        # delegates to the internally downloaded file.
        def eof?
          io.eof?
        end

        # Part of Shrine::UploadedFile's complying to the IO interface.  It
        # delegates to the internally downloaded file.
        def close
          if @io
            io.close
            io.delete if io.class.name == "Tempfile"
          end
        end

        # Part of Shrine::UploadedFile's complying to the IO interface.  It
        # delegates to the internally downloaded file.
        def rewind
          io.rewind
        end

        # Calls `#url` on the storage, forwarding any options.
        def url(**options)
          options.merge!(shrine_metadata: metadata)
          storage.url(id, **options)
        end

        # Calls `#exists?` on the storage, which checks that the file exists.
        def exists?
          storage.exists?(id)
        end

        # Uploads a new file to this file's location and returns it.
        def replace(io, context = {})
          uploader.upload(io, context.merge(location: id))
        end

        # Calls `#delete` on the storage, which deletes the remote file.
        def delete
          storage.delete(id)
        end

        # Returns the underlying IO.
        def to_io
          io
        end

        # Serializes the uploaded file to JSON, suitable for storing in the
        # column or passing to a background job.
        def to_json(*args)
          data.to_json(*args)
        end

        # Conform to ActiveSupport's JSON interface.
        def as_json(*args)
          data
        end

        # Two uploaded files are equal if they're uploaded to the same storage
        # and they have the same #id.
        def ==(other)
          other.is_a?(self.class) &&
          self.id == other.id &&
          self.storage_key == other.storage_key
        end
        alias eql? ==

        def hash
          [id, storage_key].hash
        end

        # The instance of `Shrine` with the corresponding storage.
        def uploader
          shrine_class.new(storage_key)
        end

        # The storage class this file was uploaded to.
        def storage
          shrine_class.find_storage(storage_key)
        end

        # Returns the Shrine class related to this uploaded file.
        def shrine_class
          self.class.shrine_class
        end

        # Show only the data hash in inspect output.
        def inspect
          "#{to_s.chomp(">")} @data=#{data.inspect}>"
        end

        private

        def io
          @io ||= storage.open(id)
        end
      end
    end
  end

  extend Plugins::Base::ClassMethods
  plugin Plugins::Base
end
