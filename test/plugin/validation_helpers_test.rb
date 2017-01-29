require "test_helper"
require "shrine/plugins/validation_helpers"

describe Shrine::Plugins::ValidationHelpers do
  before do
    @attacher = attacher { plugin :validation_helpers }
  end

  describe "#validate_max_size" do
    it "adds an error if file is larger than given size" do
      @attacher.assign(fakeio("image"))
      assert_equal false, @attacher.validate_max_size(1)
      refute_empty @attacher.errors
    end

    it "doesn't add an error if file is in the size limits" do
      @attacher.assign(fakeio("image"))
      assert_equal true, @attacher.validate_max_size(50)
      assert_empty @attacher.errors
    end
  end

  describe "#validate_min_size" do
    it "adds an error if file is smaller than given size" do
      @attacher.assign(fakeio("image"))
      assert_equal false, @attacher.validate_min_size(10)
      refute_empty @attacher.errors
    end

    it "doesn't add an error if file is in the size limits" do
      @attacher.assign(fakeio("image"))
      assert_equal true, @attacher.validate_min_size(1)
      assert_empty @attacher.errors
    end

    it "uses the default error messages" do
      @attacher.assign(fakeio)
      @attacher.validate_min_size 2*1024*1024
      assert_equal ["is too small (min is 2.0 MB)"], @attacher.errors
    end

    it "accepts custom error messages" do
      @attacher.assign(fakeio)
      @attacher.validate_min_size 2*1024*1024, message: ->(min) { "< #{min/1024/1024}" }
      assert_equal ["< 2"], @attacher.errors

      @attacher.assign(fakeio)
      @attacher.validate_min_size 2*1024*1024, message: "is too small"
      assert_equal ["is too small"], @attacher.errors
    end
  end

  describe "#validate_max_width" do
    it "adds an error if file is wider than given size" do
      @attacher.shrine_class.plugin :store_dimensions
      @attacher.assign(image)
      assert_equal false, @attacher.validate_max_width(10)
      refute_empty @attacher.errors
    end

    it "doesn't add an error if file is in the dimension limits" do
      @attacher.shrine_class.plugin :store_dimensions
      @attacher.assign(image)
      assert_equal true, @attacher.validate_max_width(500)
      assert_empty @attacher.errors
    end

    it "requires the store_dimensions plugin" do
      @attacher.assign(image)
      assert_raises(Shrine::Error) { @attacher.validate_max_width(500) }
    end
  end

  describe "#validate_min_width" do
    it "adds an error if file is narrower than given size" do
      @attacher.shrine_class.plugin :store_dimensions
      @attacher.assign(image)
      assert_equal false, @attacher.validate_min_width(500)
      refute_empty @attacher.errors
    end

    it "doesn't add an error if file is in the dimension limits" do
      @attacher.shrine_class.plugin :store_dimensions
      @attacher.assign(image)
      assert_equal true, @attacher.validate_min_width(10)
      assert_empty @attacher.errors
    end

    it "requires the store_dimensions plugin" do
      @attacher.assign(image)
      assert_raises(Shrine::Error) { @attacher.validate_min_width(10) }
    end
  end

  describe "#validate_max_height" do
    it "adds an error if file is wider than given size" do
      @attacher.shrine_class.plugin :store_dimensions
      @attacher.assign(image)
      assert_equal false, @attacher.validate_max_height(10)
      refute_empty @attacher.errors
    end

    it "doesn't add an error if file is in the dimension limits" do
      @attacher.shrine_class.plugin :store_dimensions
      @attacher.assign(image)
      assert_equal true, @attacher.validate_max_height(500)
      assert_empty @attacher.errors
    end

    it "requires the store_dimensions plugin" do
      @attacher.assign(image)
      assert_raises(Shrine::Error) { @attacher.validate_max_height(500) }
    end
  end

  describe "#validate_min_height" do
    it "adds an error if file is narrower than given size" do
      @attacher.shrine_class.plugin :store_dimensions
      @attacher.assign(image)
      assert_equal false, @attacher.validate_min_height(500)
      refute_empty @attacher.errors
    end

    it "doesn't add an error if file is in the dimension limits" do
      @attacher.shrine_class.plugin :store_dimensions
      @attacher.assign(image)
      assert_equal true, @attacher.validate_min_height(1)
      assert_empty @attacher.errors
    end

    it "requires the store_dimensions plugin" do
      @attacher.assign(image)
      assert_raises(Shrine::Error) { @attacher.validate_min_height(10) }
    end
  end

  describe "#validate_mime_type_inclusion" do
    it "adds an error when mime_type is not in the whitelist" do
      @attacher.assign(fakeio(content_type: "video/mpeg"))
      assert_equal false, @attacher.validate_mime_type_inclusion(["image/jpeg", "image/png"])
      refute_empty @attacher.errors

      @attacher.assign(fakeio(content_type: "image/jpeg"))
      assert_equal true, @attacher.validate_mime_type_inclusion(["image/jpeg", "image/png"])
      assert_empty @attacher.errors
    end

    it "scans multiline strings" do
      @attacher.assign(fakeio(content_type: "video/mpeg\nfoo"))
      @attacher.validate_mime_type_inclusion ["video/mpeg"]
      refute_empty @attacher.errors
    end

    it "adds an error if mime_type is missing" do
      @attacher.assign(fakeio)
      assert_equal false, @attacher.validate_mime_type_inclusion(["image/jpeg"])
      refute_empty @attacher.errors
    end
  end

  describe "#validate_mime_type_exclusion" do
    it "adds an error when mime_type is in the blacklist" do
      @attacher.assign(fakeio(content_type: "video/mpeg"))
      assert_equal false, @attacher.validate_mime_type_exclusion(["video/mpeg", "audio/mp3"])
      refute_empty @attacher.errors

      @attacher.assign(fakeio(content_type: "image/jpeg"))
      assert_equal true, @attacher.validate_mime_type_exclusion(["video/mpeg", "audio/mp3"])
      assert_empty @attacher.errors
    end

    it "doesn't add an error if mime_type is missing" do
      @attacher.assign(fakeio)
      assert_equal true, @attacher.validate_mime_type_exclusion(["video/mpeg"])
      assert_empty @attacher.errors
    end
  end

  describe "#validate_extension_inclusion" do
    it "adds an error when extension is not in the whitelist" do
      @attacher.assign(fakeio(filename: "video.mp4"))
      assert_equal false, @attacher.validate_extension_inclusion(["jpg", "png"])
      refute_empty @attacher.errors

      @attacher.assign(fakeio(filename: "image.jpg"))
      assert_equal true, @attacher.validate_extension_inclusion(["jpg", "png"])
      assert_empty @attacher.errors
    end

    it "matches extension insensitive to case" do
      @attacher.assign(fakeio(filename: "image.JPG"))
      @attacher.validate_extension_inclusion ["jpg"]
      assert_empty @attacher.errors
    end

    it "adds an error if extension is missing" do
      @attacher.assign(fakeio)
      assert_equal false, @attacher.validate_extension_inclusion(["jpg"])
      refute_empty @attacher.errors
    end

    it "anchors the regexes of the converted strings" do
      @attacher.assign(fakeio(filename: "video.mp4foobar"))
      @attacher.validate_extension_inclusion ["mp4"]
      refute_empty @attacher.errors
    end
  end

  describe "#validate_extension_exclusion" do
    it "adds an error when extension is in the blacklist" do
      @attacher.assign(fakeio(filename: "video.mp4"))
      assert_equal false, @attacher.validate_extension_exclusion(["mp4", "mp3"])
      refute_empty @attacher.errors

      @attacher.assign(fakeio(filename: "image.jpg"))
      assert_equal true, @attacher.validate_extension_exclusion(["mp4", "mp3"])
      assert_empty @attacher.errors
    end

    it "matches extension insensitive to case" do
      @attacher.assign(fakeio(filename: "image.JPG"))
      @attacher.validate_extension_exclusion ["jpg"]
      refute_empty @attacher.errors
    end

    it "doesn't add an error if extension is missing" do
      @attacher.assign(fakeio)
      assert_equal true, @attacher.validate_extension_exclusion(["mp4"])
      assert_empty @attacher.errors
    end
  end

  describe "#validate_filename_max_length" do
    it "adds an error when filename length is too long" do
      @attacher.assign(fakeio(filename: "invalid.jpg"))
      assert_equal false, @attacher.validate_filename_max_length(10)
      refute_empty @attacher.errors

      @attacher.assign(fakeio(filename: "valid.jpg"))
      assert_equal true, @attacher.validate_filename_max_length(10)
      assert_empty @attacher.errors
    end

    it "uses the default error messages" do
      @attacher.assign(fakeio(filename: "invalid.jpg"))
      @attacher.validate_filename_max_length(10)
      assert_equal ["is too long (max is 10 characters)"], @attacher.errors
    end

    it "accepts custom error messages" do
      @attacher.assign(fakeio(filename: "invalid.jpg"))
      @attacher.validate_filename_max_length 10, message: ->(max) { "is longer than the #{max} characters permitted" }
      assert_equal ["is longer than the 10 characters permitted"], @attacher.errors

      @attacher.assign(fakeio(filename: "invalid.jpg"))
      @attacher.validate_filename_max_length 10, message: "is too long"
      assert_equal ["is too long"], @attacher.errors
    end
  end
end
