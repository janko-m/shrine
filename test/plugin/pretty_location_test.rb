require "test_helper"
require "shrine/plugins/pretty_location"
require "ostruct"

describe Shrine::Plugins::PrettyLocation do
  module NameSpaced
    class OpenStruct < ::OpenStruct; end
  end

  before do
    @uploader = uploader { plugin :pretty_location }
  end

  it "uses context to build the directory" do
    uploaded_file = @uploader.upload(fakeio, record: OpenStruct.new(id: 123), name: :avatar)
    assert_match %r{^openstruct/123/avatar/[\w-]+$}, uploaded_file.id
  end

  it "prepends version names to generated location" do
    uploaded_file = @uploader.upload(fakeio(filename: "foo.jpg"), version: :thumb)
    assert_match %r{^thumb-[\w-]+\.jpg$}, uploaded_file.id
  end

  it "includes only the inner class in location by default" do
    uploaded_file = @uploader.upload(fakeio, record: NameSpaced::OpenStruct.new(id: 123), name: :avatar)
    assert_match %r{^openstruct/123/avatar/[\w-]+$}, uploaded_file.id
  end

  it "includes class namespace when :namespace is set" do
    @uploader.class.plugin :pretty_location, namespace: "_"
    uploaded_file = @uploader.upload(fakeio, record: NameSpaced::OpenStruct.new(id: 123), name: :avatar)
    assert_match %r{^namespaced_openstruct/123/avatar/[\w-]+$}, uploaded_file.id
  end

  it "includes owner and owner id when owner is a direct association" do
    @uploader.class.plugin :pretty_location, namespace: "_", owner: 'User'
    uploaded_file = @uploader.upload(fakeio, record: NameSpaced::OpenStruct.new(id: 123, user_id: 1), name: :avatar)
    assert_match %r{^user/1/namespaced_openstruct/123/avatar/[\w-]+$}, uploaded_file.id
  end

  it "includes owner and owner id when owner is a polymorphic association" do
    @uploader.class.plugin :pretty_location, namespace: "_", owner: 'Owner'
    uploaded_file = @uploader.upload(fakeio, record: NameSpaced::OpenStruct.new(id: 123, owner_type: 'User', owner_id: 1), name: :avatar)
    assert_match %r{^user/1/namespaced_openstruct/123/avatar/[\w-]+$}, uploaded_file.id
  end
end
