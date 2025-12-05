# frozen_string_literal: true

require "json"
require_relative "base"

module LLM
  module Cache
    module CacheStores
      class Redis < Base
        def initialize(config)
          super
          setup_client
        end

        def get(id)
          key = cache_key(id)
          data = @client.call("GET", key)
          return nil unless data

          JSON.parse(data, symbolize_names: true)
        rescue JSON::ParserError
          nil
        end

        def set(id, data, ttl: nil)
          key = cache_key(id)
          json = JSON.generate(data)

          if ttl
            @client.call("SETEX", key, ttl.to_i, json)
          else
            @client.call("SET", key, json)
          end
        end

        def delete(id)
          key = cache_key(id)
          @client.call("DEL", key)
        end

        def clear!
          pattern = cache_key("*")
          cursor = "0"

          loop do
            cursor, keys = @client.call("SCAN", cursor, "MATCH", pattern, "COUNT", 100)
            @client.call("DEL", *keys) unless keys.empty?
            break if cursor == "0"
          end
        end

        def empty?
          size.zero?
        end

        def size
          pattern = cache_key("*")
          count = 0
          cursor = "0"

          loop do
            cursor, keys = @client.call("SCAN", cursor, "MATCH", pattern, "COUNT", 100)
            count += keys.size
            break if cursor == "0"
          end

          count
        end

        private

        def setup_client
          require "redis-client"

          @client = if @config.redis_client
                      @config.redis_client
                    elsif @config.redis_url
                      RedisClient.config(url: @config.redis_url).new_client
                    else
                      RedisClient.config.new_client
                    end
        end

        def cache_key(id)
          "#{@config.namespace}:cache:#{id}"
        end
      end
    end
  end
end
