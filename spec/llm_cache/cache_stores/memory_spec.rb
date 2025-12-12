# frozen_string_literal: true

RSpec.describe LLMCache::CacheStores::Memory do
  let(:config) { LLMCache::Configuration.new }
  let(:store) { described_class.new(config) }

  describe "#set and #get" do
    it "stores and retrieves data" do
      store.set("id1", { query: "test", response: "answer" })

      result = store.get("id1")

      expect(result).to eq({ query: "test", response: "answer" })
    end

    it "returns nil for non-existent keys" do
      result = store.get("nonexistent")

      expect(result).to be_nil
    end
  end

  describe "TTL support" do
    it "expires entries after TTL" do
      store.set("id1", { query: "test" }, ttl: 0.1)

      expect(store.get("id1")).to eq({ query: "test" })

      sleep 0.15

      expect(store.get("id1")).to be_nil
    end

    it "does not expire entries without TTL" do
      store.set("id1", { query: "test" })

      sleep 0.1

      expect(store.get("id1")).to eq({ query: "test" })
    end
  end

  describe "#delete" do
    it "removes an entry by id" do
      store.set("id1", { query: "test1" })
      store.set("id2", { query: "test2" })

      store.delete("id1")

      expect(store.get("id1")).to be_nil
      expect(store.get("id2")).to eq({ query: "test2" })
    end
  end

  describe "#clear!" do
    it "removes all entries" do
      store.set("id1", { query: "test1" })
      store.set("id2", { query: "test2" })

      store.clear!

      expect(store.empty?).to be true
      expect(store.size).to eq(0)
    end
  end

  describe "#size and #empty?" do
    it "tracks the number of entries" do
      expect(store.empty?).to be true
      expect(store.size).to eq(0)

      store.set("id1", { query: "test" })

      expect(store.empty?).to be false
      expect(store.size).to eq(1)
    end

    it "excludes expired entries from count" do
      store.set("id1", { query: "test" }, ttl: 0.1)

      expect(store.size).to eq(1)

      sleep 0.15

      expect(store.size).to eq(0)
      expect(store.empty?).to be true
    end
  end
end
