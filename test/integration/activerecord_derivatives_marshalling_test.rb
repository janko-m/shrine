require "test_helper"
require "./test/support/activerecord"

describe "ActiveRecord & derivatives marshalling" do
  before do
    @shrine = shrine do
      plugin :sequel
      plugin :derivatives
    end

    user_class = Class.new(ActiveRecord::Base)
    user_class.table_name = :users
    user_class.class_eval do
      # needed for translating validation errors
      def self.model_name
        ActiveModel::Name.new(self, nil, "User")
      end
    end
    user_class.include @shrine::Attachment.new(:avatar)

    @user = user_class.create!

    # we can't Marshal anonymous classes
    Shrine::TestUploaderClass = @shrine
    Shrine::TestUserClass = user_class
  end

  after do
    Shrine.send(:remove_const, :TestUserClass)
    Shrine.send(:remove_const, :TestUploaderClass)
  end

  specify "marshalling does not raise any errors" do
    Marshal.load(Marshal.dump(@user.avatar_attacher))
  end
end
