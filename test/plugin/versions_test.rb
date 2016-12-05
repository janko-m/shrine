require "test_helper"
require "shrine/plugins/versions"

describe Shrine::Plugins::Versions do
  before do
    @attacher = attacher { plugin :versions }
    @uploader = @attacher.store
  end

  it "allows uploading versions" do
    versions = @uploader.upload(thumb: fakeio)
    assert_kind_of Shrine::UploadedFile, versions.fetch(:thumb)
  end

  it "allows processing into versions" do
    @uploader.instance_eval { def process(io, context); {thumb: io}; end }
    versions = @uploader.upload(fakeio("file"))
    assert_equal "file", versions.fetch(:thumb).read
  end

  it "allows reprocessing versions" do
    @uploader.instance_eval { def process(hash, context); {thumb: hash.fetch(:thumb)}; end }
    versions = @uploader.upload(thumb: fakeio("thumb"))
    assert_equal "thumb", versions.fetch(:thumb).read
  end

  it "makes #uploaded_file recognize versions" do
    uploaded_file = @uploader.upload(fakeio)
    retrieved = @uploader.class.uploaded_file("thumb" => uploaded_file.data)
    assert_equal Hash[thumb: uploaded_file], retrieved
  end

  it "passes the version name to location generator" do
    @uploader.instance_eval { def generate_location(io, version:, **); version.to_s; end }
    versions = @uploader.upload(thumb: fakeio)
    assert_equal "thumb", versions.fetch(:thumb).id
  end

  it "extends Shrine#uploaded?" do
    versions = @uploader.upload(thumb: fakeio)
    assert @uploader.uploaded?(versions)
  end

  it "enables deleting versions" do
    versions = @uploader.upload(thumb: fakeio)
    deleted_versions = @uploader.delete(versions)
    assert_equal versions, deleted_versions
    refute deleted_versions[:thumb].exists?
  end

  describe "Attacher#url" do
    it "accepts a version name" do
      @attacher.set(thumb: @uploader.upload(fakeio))
      assert_equal @attacher.get[:thumb].url, @attacher.url(:thumb)
    end

    it "returns nil when a attachment doesn't exist" do
      assert_nil @attacher.url(:thumb)
    end

    it "doesn't fail if version is registered but missing" do
      @attacher.set({})
      @attacher.class.default_url { |options| "missing #{options[:version]}" }
      assert_equal "missing thumb", @attacher.url(:thumb)
    end

    it "returns raw file URL if versions haven't been generated" do
      @attacher.assign(fakeio)
      assert_equal @attacher.url, @attacher.url(:thumb)
    end

    it "doesn't allow no argument when attachment is versioned" do
      @attacher.set(thumb: @uploader.upload(fakeio))
      assert_raises(Shrine::Error) { @attacher.url }
    end

    it "passes in :version to the default url" do
      @attacher.class.default_url { |options| "missing #{options[:version]}" }
      assert_equal "missing thumb", @attacher.url(:thumb)
    end

    it "forwards url options" do
      @attacher.set(thumb: @attacher.store!(fakeio))
      Shrine::UploadedFile.any_instance.expects(:url).with(foo: "foo")
      @attacher.url(:thumb, foo: "foo")
      @attacher.set(@attacher.store!(fakeio))
      Shrine::UploadedFile.any_instance.expects(:url).with(foo: "foo")
      @attacher.url(:thumb, foo: "foo")
      Shrine::UploadedFile.any_instance.expects(:url).with(foo: "foo")
      @attacher.url(foo: "foo")

      @attacher.set(original: @attacher.store!(fakeio))
      @attacher.expects(:default_url).with(version: :thumb, foo: "foo")
      @attacher.url(:thumb, foo: "foo")
      @attacher.set(nil)
      @attacher.expects(:default_url).with(version: :thumb, foo: "foo")
      @attacher.url(:thumb, foo: "foo")
    end

    it "supports :fallbacks" do
      @attacher.shrine_class.opts[:version_fallbacks] = {
        medium: :thumb,
        large:  :medium,
      }
      @attacher.set(thumb: @attacher.store!(fakeio))
      assert_equal @attacher.url(:thumb), @attacher.url(:medium)
      assert_equal @attacher.url(:thumb), @attacher.url(:large)
    end

    it "supports :fallback_to_original" do
      @attacher.shrine_class.plugin :versions, fallback_to_original: false

      @attacher.expects(:default_url).with(version: :thumbnail, foo: "foo")
      @attacher.url(:thumbnail, foo: "foo")

      @attacher.assign(fakeio)
      @attacher.expects(:default_url).with(version: :thumbnail, foo: "foo")
      @attacher.url(:thumbnail, foo: "foo")
    end
  end

  describe "Attacher" do
    it "deprecates assigning cached versions" do
      versions = {thumb: @attacher.cache!(fakeio)}
      assert_output(nil, /deprecated/) { @attacher.assign(versions.to_json) }
    end

    it "destroys versions successfully" do
      @attacher.set(thumb: @uploader.upload(fakeio))
      @attacher.destroy
      refute @attacher.get[:thumb].exists?
    end

    it "replaces versions sucessfully" do
      @attacher.set(original = {thumb: @uploader.upload(fakeio)})
      @attacher.set(thumb: @uploader.upload(fakeio))
      @attacher.replace
      refute original[:thumb].exists?
    end

    it "promotes versions successfully" do
      @attacher.set(thumb: @attacher.cache!(fakeio))
      @attacher._promote
      assert @attacher.store.uploaded?(@attacher.get[:thumb])
    end
  end

  it "complains when two versions contain the same IO object" do
    io = fakeio
    assert_raises(Shrine::Error) { @uploader.upload(version1: io, version2: io) }
  end

  it "still catches invalid IOs" do
    @uploader.instance_eval { def process(io, context); {thumb: "invalid IO"}; end }
    error = assert_raises(Shrine::InvalidFile) { @uploader.upload(fakeio) }
    assert_match /is not a valid IO object/, error.message
  end

  it "doesn't allow :location" do
    assert_raises(Shrine::Error) do
      @uploader.upload({thumb: fakeio}, location: "foobar")
    end
  end
end
