# frozen_string_literal: true

module LLMCache
  # Handles serialization/deserialization of cached responses
  module Serializer
    class << self
      def serialize(response)
        if defined?(RubyLLM::Message) && response.is_a?(RubyLLM::Message)
          serialize_message(response)
        else
          serialize_basic(response)
        end
      end

      def deserialize(data)
        return data unless data.is_a?(Hash)

        type = data[:type] || data["type"]
        value = data[:value] || data["value"]

        case type
        when "rubyllm_message"
          deserialize_message(value)
        when "string", "hash", "object"
          value
        when "nil"
          nil
        else
          value
        end
      end

      private

      def serialize_basic(response)
        case response
        when String
          { type: "string", value: response }
        when Hash
          { type: "hash", value: response }
        when NilClass
          { type: "nil", value: nil }
        else
          if response.respond_to?(:to_h)
            { type: "object", class: response.class.name, value: response.to_h }
          else
            { type: "string", value: response.to_s }
          end
        end
      end

      def serialize_message(message)
        {
          type: "rubyllm_message",
          value: {
            role: message.role,
            content: serialize_content(message.content),
            model_id: message.model_id,
            tool_calls: message.tool_calls,
            tool_call_id: message.tool_call_id,
            input_tokens: message.input_tokens,
            output_tokens: message.output_tokens,
            cached_tokens: message.cached_tokens,
            cache_creation_tokens: message.cache_creation_tokens
          }.compact
        }
      end

      def serialize_content(content)
        case content
        when String
          { type: "string", value: content }
        when Hash
          { type: "hash", value: content }
        when ->(c) { defined?(RubyLLM::Content) && c.is_a?(RubyLLM::Content) }
          { type: "rubyllm_content", value: content.to_h }
        else
          { type: "string", value: content.to_s }
        end
      end

      def deserialize_message(value)
        return value unless defined?(RubyLLM::Message)

        content = deserialize_content(value[:content] || value["content"])
        RubyLLM::Message.new(
          role: (value[:role] || value["role"]).to_sym,
          content: content,
          model_id: value[:model_id] || value["model_id"],
          tool_calls: value[:tool_calls] || value["tool_calls"],
          tool_call_id: value[:tool_call_id] || value["tool_call_id"],
          input_tokens: value[:input_tokens] || value["input_tokens"],
          output_tokens: value[:output_tokens] || value["output_tokens"],
          cached_tokens: value[:cached_tokens] || value["cached_tokens"],
          cache_creation_tokens: value[:cache_creation_tokens] || value["cache_creation_tokens"]
        )
      end

      def deserialize_content(data)
        return data unless data.is_a?(Hash)

        type = data[:type] || data["type"]
        value = data[:value] || data["value"]

        case type
        when "string", "hash", "rubyllm_content"
          value
        else
          value
        end
      end
    end
  end
end
