require "test_helper"
require "shrine/plugins/store_dimensions"
require "dry-monitor"

describe Shrine::Plugins::StoreDimensions do
  before do
    @uploader = uploader { plugin :store_dimensions }
    @shrine = @uploader.class
  end

  describe ":fastimage analyzer" do
    before do
      @shrine.plugin :store_dimensions, analyzer: :fastimage
    end

    it "extracts dimensions from files" do
      assert_equal [100, 67], @shrine.extract_dimensions(image)
    end

    it "extracts dimensions from non-files" do
      assert_equal [100, 67], @shrine.extract_dimensions(fakeio(image.read))
    end

    it "returns nil for non-images" do
      assert_logged /SHRINE WARNING: Error occurred/ do
        assert_nil @shrine.extract_dimensions(fakeio)
      end
    end
  end

  describe ":mini_magick analyzer" do
    before do
      @shrine.plugin :store_dimensions, analyzer: :mini_magick
    end

    it "extracts dimensions from files" do
      assert_equal [100, 67], @shrine.extract_dimensions(image)
    end

    it "extracts dimensions from non-files" do
      assert_equal [100, 67], @shrine.extract_dimensions(fakeio(image.read))
      assert_equal [100, 67], @shrine.extract_dimensions(@uploader.upload(image))
    end

    it "returns nil for non-images" do
      assert_logged /SHRINE WARNING: Error occurred/ do
        assert_nil @shrine.extract_dimensions(fakeio)
      end
    end
  end unless ENV["CI"]

  describe ":ruby_vips analyzer" do
    before do
      @shrine.plugin :store_dimensions, analyzer: :ruby_vips
    end

    it "extracts dimensions from files" do
      assert_equal [100, 67], @shrine.extract_dimensions(image)
    end

    it "extracts dimensions from non-files" do
      assert_equal [100, 67], @shrine.extract_dimensions(fakeio(image.read))
      assert_equal [100, 67], @shrine.extract_dimensions(@uploader.upload(image))
    end

    it "returns nil for non-images" do
      assert_logged /SHRINE WARNING: Error occurred/ do
        assert_nil @shrine.extract_dimensions(fakeio)
      end
    end
  end unless ENV["CI"]

  describe "with instrumentation" do
    before do
      @shrine.plugin :instrumentation, notifications: Dry::Monitor::Notifications.new(:test)
    end

    it "logs dimensions extraction" do
      @shrine.plugin :store_dimensions

      assert_logged /^Image Dimensions \(\d+ms\) – \{.+\}$/ do
        @shrine.extract_dimensions(image)
      end
    end

    it "sends a dimensions extraction event" do
      @shrine.plugin :store_dimensions

      @shrine.subscribe(:image_dimensions) { |event| @event = event }
      @shrine.extract_dimensions(io = image)

      refute_nil @event
      assert_equal :image_dimensions, @event.name
      assert_equal io,                @event[:io]
      assert_equal @shrine,           @event[:uploader]
      assert_kind_of Integer,         @event.duration
    end

    it "allows swapping log subscriber" do
      @shrine.plugin :store_dimensions, log_subscriber: -> (event) { @event = event }

      refute_logged /^Image Dimensions/ do
        @shrine.extract_dimensions(image)
      end

      refute_nil @event
    end

    it "allows disabling log subscriber" do
      @shrine.plugin :determine_mime_type, log_subscriber: nil

      refute_logged /^Image Dimensions/ do
        @shrine.extract_dimensions(image)
      end
    end
  end

  it "respects :on_error option" do
    assert_logged /Error occurred when attempting to extract image dimensions/ do
      @shrine.extract_dimensions(fakeio)
    end

    @shrine.plugin :store_dimensions, on_error: :warn

    assert_logged /Error occurred when attempting to extract image dimensions/ do
      @shrine.extract_dimensions(fakeio)
    end

    @shrine.plugin :store_dimensions, on_error: :fail

    assert_raises FastImage::FastImageException do
      @shrine.extract_dimensions(fakeio)
    end

    @shrine.plugin :store_dimensions, on_error: :ignore

    refute_logged /Error occurred when attempting to extract image dimensions/ do
      @shrine.extract_dimensions(fakeio)
    end
  end

  it "automatically extracts dimensions on upload" do
    uploaded_file = @uploader.upload(image)
    assert_equal 100, uploaded_file.metadata["width"]
    assert_equal 67,  uploaded_file.metadata["height"]
  end

  it "maintains optional second argument for #extract_metadata" do
    @uploader.extract_metadata(fakeio)
  end

  it "allows storing with custom extractor" do
    @shrine.plugin :store_dimensions, analyzer: ->(io){[5, 10]}
    assert_equal [5, 10], @shrine.extract_dimensions(fakeio)

    @shrine.plugin :store_dimensions, analyzer: ->(io, analyzers){analyzers[:fastimage].call(io)}
    assert_equal [100, 67], @shrine.extract_dimensions(image)

    @shrine.plugin :store_dimensions, analyzer: ->(io){nil}
    assert_nil @shrine.extract_dimensions(image)
  end

  it "always rewinds the IO" do
    @shrine.plugin :store_dimensions, analyzer: ->(io){io.read; [5, 10]}
    @shrine.extract_dimensions(file = image)
    assert_equal 0, file.pos
  end

  describe "dimension methods" do
    it "adds `#width`, `#height` and `#dimensions` to UploadedFile" do
      uploaded_file = @uploader.upload(image)
      assert_equal uploaded_file.metadata["width"],                     uploaded_file.width
      assert_equal uploaded_file.metadata["height"],                    uploaded_file.height
      assert_equal uploaded_file.metadata.values_at("width", "height"), uploaded_file.dimensions
    end

    it "coerces values to Integer" do
      uploaded_file = @uploader.upload(image)
      uploaded_file.metadata["width"] = "48"
      uploaded_file.metadata["height"] = "52"
      assert_equal 48,       uploaded_file.width
      assert_equal 52,       uploaded_file.height
      assert_equal [48, 52], uploaded_file.dimensions
    end

    it "allows metadata values to be missing or nil" do
      uploaded_file = @uploader.upload(image)
      uploaded_file.metadata["width"] = nil
      uploaded_file.metadata.delete("height")
      assert_nil uploaded_file.width
      assert_nil uploaded_file.height
      assert_nil uploaded_file.dimensions
    end
  end

  it "provides access to dimensions analyzers" do
    analyzers = @shrine.dimensions_analyzers
    dimensions = analyzers[:fastimage].call(io = image)
    assert_equal [100, 67], dimensions
    assert_equal 0, io.pos
  end

  it "has .dimensions alias" do
    assert_equal [100, 67], @shrine.dimensions(image)
  end

  it "returns Shrine::Error on unknown analyzer" do
    assert_raises Shrine::Error do
      @shrine.plugin :store_dimensions, analyzer: :foo
      @shrine.extract_dimensions(image)
    end
  end

  describe "auto_extraction: false" do
    it "does not add metadata" do
      @shrine.plugin :store_dimensions, auto_extraction: false
      uploaded_file = @uploader.upload(image)
      assert_nil uploaded_file.metadata["width"]
      assert_nil uploaded_file.metadata["height"]
    end

    it "provides method to extract dimensions from files" do
      assert_equal [100, 67], @shrine.extract_dimensions(image)
    end
  end
end
