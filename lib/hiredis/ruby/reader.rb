module Hiredis
  module Ruby
    class Reader

      def initialize
        @buffer = Buffer.new
        @task = Task.new(@buffer)
      end

      def feed(data)
        @buffer << data
      end

      def gets
        reply = @task.process
        @buffer.discard!
        reply
      end

    protected

      class Task

        # Use lookup table to map reply types to methods
        method_index = {}
        method_index[?-] = :process_error_reply
        method_index[?+] = :process_status_reply
        method_index[?:] = :process_integer_reply
        method_index[?$] = :process_bulk_reply
        method_index[?*] = :process_multi_bulk_reply
        METHOD_INDEX = method_index.freeze

        attr_accessor :parent, :child
        attr_accessor :multi_bulk

        def initialize(buffer, parent = nil, depth = 0)
          @buffer, @parent = buffer, parent

          # Require 3 nested tasks
          @child = Task.new(@buffer, self, depth + 1) if depth < 2
        end

        def root
          parent ? parent.root : self
        end

        # Set error ivar on object itself when this is the root task,
        # otherwise on the root multi bulk.
        def set_error_object(err)
          obj = parent ? root.multi_bulk : err
          if !obj.instance_variable_defined?(:@__hiredis_error)
            obj.instance_variable_set(:@__hiredis_error, err)
          end
          err
        end

        def reset!
          @line = @type = @multi_bulk = nil
        end

        def process_error_reply
          set_error_object RuntimeError.new(@line)
        end

        def process_status_reply
          @line
        end

        def process_integer_reply
          @line.to_i
        end

        def process_bulk_reply
          bulk_length = @line.to_i
          return nil if bulk_length < 0

          # Caught by caller function when false
          @buffer.read(bulk_length, 2)
        end

        def process_multi_bulk_reply
          multi_bulk_length = @line.to_i

          if multi_bulk_length > 0
            @multi_bulk ||= []

            # We know the multi bulk is not complete when this path is taken.
            while (element = child.process) != false
              @multi_bulk << element
              return @multi_bulk if @multi_bulk.length == multi_bulk_length
            end

            false
          elsif multi_bulk_length == 0
            []
          else
            nil
          end
        end

        def process_protocol_error
          raise "Protocol error"
        end

        def process
          @line ||= @buffer.read_line
          return false if @line == false

          @type ||= @line.slice!(0)
          reply = send(METHOD_INDEX[@type] || :process_protocol_error)

          reset! if reply != false
          reply
        end
      end

      class Buffer

        CRLF = "\r\n".freeze

        def initialize
          @buffer = ""
          @length = @pos = 0
        end

        def <<(data)
          @length += data.length
          @buffer << data
        end

        def length
          @length
        end

        def empty?
          @length == 0
        end

        def discard!
          if @length == 0
            @buffer = ""
            @length = @pos = 0
          else
            if @pos >= 1024
              @buffer.slice!(0, @pos)
              @length -= @pos
              @pos = 0
            end
          end
        end

        def read(bytes, skip = 0)
          start = @pos
          stop = start + bytes + skip
          return false if @length < stop

          @pos = stop
          @buffer[start, bytes]
        end

        def read_line
          start = @pos
          stop = @buffer.index(CRLF, @pos)
          return false unless stop

          @pos = stop + 2 # include CRLF
          @buffer[start, stop - start]
        end
      end
    end
  end
end
