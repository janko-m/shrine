require "test_helper"

describe "the store_dimensions plugin" do
  before do
    @uploader = uploader do
      plugin :store_dimensions, analyzer: :fastimage
    end
  end

  describe ":fastimage" do
    it "extracts dimensions from files" do
      uploaded_file = @uploader.upload(image)
      assert_equal 100, uploaded_file.metadata["width"]
      assert_equal 67, uploaded_file.metadata["height"]
    end

    it "extracts dimensions from non-files" do
      uploaded_file = @uploader.upload(fakeio(image.read))
      assert_equal 100, uploaded_file.metadata["width"]
      assert_equal 67, uploaded_file.metadata["height"]
    end

    # https://github.com/sdsykes/fastimage/pull/66
    it "rewinds the IO even in case of invalid image" do
      uploaded_file = @uploader.upload(io = fakeio("content"))
      assert_equal "content", uploaded_file.read
      assert_equal nil, uploaded_file.metadata["width"]
      assert_equal nil, uploaded_file.metadata["height"]
    end
  end

  it "extracts dimensions from UploadedFiles" do
    uploaded_file = @uploader.upload(image)
    width, height = @uploader.extract_dimensions(uploaded_file)
    assert_equal 100, width
    assert_equal 67, height
  end

  it "gives UploadedFile `width` and `height` methods" do
    uploaded_file = @uploader.upload(image)
    assert_equal uploaded_file.metadata["width"], uploaded_file.width
    assert_equal uploaded_file.metadata["height"], uploaded_file.height
  end

  it "coerces the dimensions to integer" do
    uploaded_file = @uploader.upload(image)
    uploaded_file.metadata["width"] = "48"
    uploaded_file.metadata["height"] = "52"
    assert_equal 48, uploaded_file.width
    assert_equal 52, uploaded_file.height
  end

  it "allows dimensions to be missing or nil" do
    uploaded_file = @uploader.upload(image)
    uploaded_file.metadata["width"] = nil
    uploaded_file.metadata.delete("height")
    assert_equal nil, uploaded_file.width
    assert_equal nil, uploaded_file.height
  end

  it "allows storing with custom extractor" do
    @uploader = uploader do
      plugin :store_dimensions, analyzer: ->(io){[5, 10]}
    end
    uploaded_file = @uploader.upload(image)
    assert_equal 5, uploaded_file.metadata["width"]
    assert_equal 10, uploaded_file.metadata["height"]
  end
end