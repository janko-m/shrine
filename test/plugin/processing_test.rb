require "test_helper"
require "shrine/plugins/processing"

describe Shrine::Plugins::Processing do
  before do
    @uploader = uploader { plugin :processing }
  end

  it "executes defined processing" do
    @uploader.class.process(:foo) { |io, context| FakeIO.new(io.read.reverse) }
    uploaded_file = @uploader.upload(fakeio("file"), action: :foo)
    assert_equal "elif", uploaded_file.read
  end

  it "executes in context of uploader, and passes right variables" do
    @uploader.class.process(:foo) do |io, context|
      raise unless self.is_a?(Shrine)
      raise unless io.respond_to?(:read)
      raise unless context.is_a?(Hash) && context.key?(:action)
      FakeIO.new(io.read.reverse)
    end
    @uploader.upload(fakeio("file"), action: :foo)
  end

  it "executes all defined blocks where output of previous is input to next" do
    @uploader.class.process(:foo) { |io, context| FakeIO.new("changed") }
    @uploader.class.process(:foo) { |io, context| FakeIO.new(io.read.reverse) }
    uploaded_file = @uploader.upload(fakeio("file"), action: :foo)
    assert_equal "degnahc", uploaded_file.read
  end

  it "allows blocks to return nil" do
    @uploader.class.process(:foo) { |io, context| nil }
    @uploader.class.process(:foo) { |io, context| FakeIO.new(io.read.reverse) }
    uploaded_file = @uploader.upload(fakeio("file"), action: :foo)
    assert_equal "elif", uploaded_file.read
  end

  it "executes defined blocks only if phases match" do
    @uploader.class.process(:foo) { |io, context| FakeIO.new(io.read.reverse) }
    uploaded_file = @uploader.upload(fakeio("file"))
    assert_equal "file", uploaded_file.read
  end

  it "has #process return nil when there are no blocks defined" do
    assert_nil @uploader.process(fakeio)
  end
end
