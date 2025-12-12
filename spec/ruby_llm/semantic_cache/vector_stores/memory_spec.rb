# frozen_string_literal: true

RSpec.describe RubyLLM::SemanticCache::VectorStores::Memory do
  let(:config) { RubyLLM::SemanticCache::Configuration.new }
  let(:store) { described_class.new(config) }

  describe "#add and #search" do
    it "adds vectors and finds them by similarity" do
      store.add("id1", [1.0, 0.0, 0.0])
      store.add("id2", [0.0, 1.0, 0.0])
      store.add("id3", [0.9, 0.1, 0.0])

      results = store.search([1.0, 0.0, 0.0], limit: 2)

      expect(results.size).to eq(2)
      expect(results.first[:id]).to eq("id1")
      expect(results.first[:similarity]).to be_within(0.01).of(1.0)
    end

    it "returns results sorted by similarity descending" do
      store.add("id1", [1.0, 0.0, 0.0])
      store.add("id2", [0.5, 0.5, 0.0])
      store.add("id3", [0.9, 0.1, 0.0])

      results = store.search([1.0, 0.0, 0.0], limit: 3)

      similarities = results.map { |r| r[:similarity] }
      expect(similarities).to eq(similarities.sort.reverse)
    end

    it "respects the limit parameter" do
      5.times { |i| store.add("id#{i}", [rand, rand, rand]) }

      results = store.search([1.0, 0.0, 0.0], limit: 2)

      expect(results.size).to eq(2)
    end

    it "returns empty array when store is empty" do
      results = store.search([1.0, 0.0, 0.0])

      expect(results).to eq([])
    end
  end

  describe "#delete" do
    it "removes a vector by id" do
      store.add("id1", [1.0, 0.0, 0.0])
      store.add("id2", [0.0, 1.0, 0.0])

      store.delete("id1")

      results = store.search([1.0, 0.0, 0.0], limit: 5)
      ids = results.map { |r| r[:id] }
      expect(ids).not_to include("id1")
      expect(ids).to include("id2")
    end
  end

  describe "#clear!" do
    it "removes all vectors" do
      store.add("id1", [1.0, 0.0, 0.0])
      store.add("id2", [0.0, 1.0, 0.0])

      store.clear!

      expect(store.empty?).to be true
      expect(store.size).to eq(0)
    end
  end

  describe "#size and #empty?" do
    it "tracks the number of vectors" do
      expect(store.empty?).to be true
      expect(store.size).to eq(0)

      store.add("id1", [1.0, 0.0, 0.0])

      expect(store.empty?).to be false
      expect(store.size).to eq(1)
    end
  end

  describe "cosine similarity calculation" do
    it "returns 1.0 for identical vectors" do
      store.add("id1", [1.0, 2.0, 3.0])

      results = store.search([1.0, 2.0, 3.0], limit: 1)

      expect(results.first[:similarity]).to be_within(0.0001).of(1.0)
    end

    it "returns 0.0 for orthogonal vectors" do
      store.add("id1", [1.0, 0.0, 0.0])

      results = store.search([0.0, 1.0, 0.0], limit: 1)

      expect(results.first[:similarity]).to be_within(0.0001).of(0.0)
    end

    it "handles normalized and unnormalized vectors" do
      store.add("id1", [3.0, 4.0]) # Not normalized

      results = store.search([6.0, 8.0], limit: 1) # Same direction, different magnitude

      expect(results.first[:similarity]).to be_within(0.0001).of(1.0)
    end
  end
end
