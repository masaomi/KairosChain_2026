# frozen_string_literal: true

module Kairomone
  module Console
    # The console's account of one Claude Code child. Every stream line
    # becomes numbered events that every page connection replays in full; the
    # only things written back are the console's own control requests,
    # permission answers and owner messages. Nothing is allowed by default, by
    # timeout or because an echo said so, and no control request other than a
    # tool permission is ever answered with allow.
    #
    # Writes to the child are collected under the lock and handed to the
    # writer after it is released, so a writer that blocks or answers at once
    # (a test fake) can never stall the reader or re-enter a half-made change.
    class Session
      ASKING_WORD = 'default'
      MESSAGE_LIMIT = 32 * 1024
      DENY_MESSAGES = {
        'owner' => 'The owner denied this in the Kairomone console.',
        'console_stop' => 'The Kairomone console stopped before this was answered; it was not allowed.',
        'console' => 'The Kairomone console denied this request without asking the owner.'
      }.freeze
      LOG_TOKEN = /\A[\w.:-]{1,128}\z/

      def initialize(writer:, clock: -> { Time.now.utc }, memory_cap_bytes: 64 * 1024 * 1024, log: ->(_h) {})
        @writer = writer
        @clock = clock
        @cap = memory_cap_bytes
        @log = log
        @monitor = Monitor.new
        @outbox = nil
        @events = []
        @bytes = 0
        @seq = 0
        @counter = 0
        @started = @stopped = @exited = @capped = false
        @session_id = nil
        @mode_word = nil      # the CLI's latest reported word
        @confirmed = nil      # the word the console last confirmed; nil = none
        @mode_request = nil   # the one mode change awaiting the CLI's answer
        @interrupt_ids = {}
        @pending = {}         # request_id => {tool_use_id, tool_name, input}
        @answered = {}        # request_id => decision sent
        @answer_for_tool = {} # tool_use_id => decision sent
        @tool_names = {}
        @unreplayed = []      # owner messages sent and not yet echoed back
        @turn_open = @turn_replayed = @turn_foreign = false
        @accepting = false
        @accept_reason = 'mode_unconfirmed'
        @log_failed = false
      end

      def start!(resumed: false, session_id: nil)
        transaction do
          raise Error, 'The session was already started' if @started
          @started = true
          @session_id = session_id
          emit('child_started', 'session_id' => session_id, 'resumed' => resumed ? true : false)
          record('child_started', 'resumed' => resumed ? true : false, 'session_id' => token(session_id))
          refresh_accepting(force: true)
          request_mode_change(ASKING_WORD, by: 'console')
          true
        end
      end

      def handle_line(line)
        transaction do
          message = parse(line)
          dispatch(message) if message
          refresh_accepting
          nil
        rescue StandardError => e
          notice("The console could not process a line from Claude Code (#{e.class}); it changed nothing.")
          nil
        end
      end

      def send_message(text)
        transaction do
          reason = refusal
          next [:refused, reason] if reason
          text = utf8(text)
          next [:refused, 'invalid_text'] unless text
          next [:refused, 'empty'] if text.strip.empty?
          next [:refused, 'too_long'] if text.bytesize > MESSAGE_LIMIT
          @unreplayed << { 'text' => text, 'cancellable' => false }
          emit('owner_message', 'text' => text)
          refresh_accepting
          deliver('type' => 'user', 'message' => { 'role' => 'user', 'content' => text })
          :accepted
        end
      end

      # => :ok | :not_found | :answered | :not_allowable (an allow for a
      # request whose input cannot be shown exactly; it stays pending).
      def answer_permission(request_id, decision)
        raise ArgumentError, 'decision must be "allow" or "deny"' unless %w[allow deny].include?(decision)
        transaction do
          next :answered if @answered.key?(request_id)
          next :not_found unless @pending.key?(request_id)
          next :not_allowable if decision == 'allow' && !@pending[request_id]['exact']
          resolve(request_id, decision, by: 'owner')
          :ok
        end
      end

      def request_mode(mode)
        transaction do
          target = { 'auto' => 'auto', 'ask' => ASKING_WORD }[mode]
          next [:refused, 'invalid_mode'] unless target
          next [:refused, 'stopped'] if @stopped || @exited
          next [:refused, 'not_started'] unless @started
          next [:refused, 'mode_change_pending'] if @mode_request
          request_mode_change(target, by: 'owner')
          refresh_accepting
          :sent
        end
      end

      def interrupt!
        transaction do
          next false unless @started && !@exited
          interrupt_turn('owner')
          refresh_accepting
          true
        end
      end

      def stop!(by:)
        transaction do
          next false if @stopped
          @stopped = true
          @pending.keys.each { |id| resolve(id, 'deny', by: 'console_stop') }
          interrupt_turn('stop') if @started && !@exited
          record('stop', 'by' => token(by.to_s))
          refresh_accepting
          true
        end
      end

      def child_exited(status)
        transaction do
          next false if @exited
          @exited = true
          code = exit_code(status)
          emit('child_exited', 'status' => code)
          record('child_exited', 'status' => code)
          refresh_accepting
          true
        end
      end

      def notice(text)
        transaction { emit('notice', 'text' => text.to_s) }
      end

      def events_after(seq)
        seq = Integer(seq)
        @monitor.synchronize { (@events[[seq, 0].max..] || []).dup }
      end

      def last_seq = @monitor.synchronize { @seq }
      def mode_word = @monitor.synchronize { @mode_word }
      def asking? = @monitor.synchronize { @mode_word == ASKING_WORD }
      def accepting? = @monitor.synchronize { @accepting }
      def accept_reason = @monitor.synchronize { @accept_reason }
      def pending_ids = @monitor.synchronize { @pending.keys }
      def session_id = @monitor.synchronize { @session_id }
      def stopped? = @monitor.synchronize { @stopped }

      private

      # Runs a change under the lock, then delivers what it queued, in order.
      def transaction
        outbox = nil
        result = @monitor.synchronize do
          outer = @outbox.nil?
          @outbox ||= []
          begin
            yield
          ensure
            if outer
              outbox = @outbox
              @outbox = nil
            end
          end
        end
        outbox&.each { |message| send_to_child(message) }
        result
      end

      def deliver(message)
        @outbox << message
      end

      def send_to_child(message)
        @writer.call(message)
      rescue StandardError
        @monitor.synchronize { emit('notice', 'text' => 'The console could not write to Claude Code; the child may have ended.') }
      end

      def dispatch(message)
        case message['type']
        when 'control_request' then on_control_request(message)
        when 'control_response' then on_control_response(message)
        when 'control_cancel_request' then on_cancel(message)
        when 'system' then on_system(message)
        when 'assistant' then on_assistant(message)
        when 'user' then on_user(message)
        when 'result' then on_result(message)
        end
        # rate_limit_event, command_lifecycle and other bookkeeping lines carry
        # nothing the page shows and change nothing here.
      end

      def parse(line)
        text = utf8(line.to_s)
        unless text
          notice('Claude Code wrote a line that is not valid UTF-8; it changed nothing.')
          return nil
        end
        return nil if text.strip.empty?
        message = JSON.parse(text)
        return message if message.is_a?(Hash)
        notice('Claude Code wrote a line that is not a JSON object; it changed nothing.')
        nil
      rescue JSON::ParserError
        notice('Claude Code wrote a line that is not JSON; it changed nothing.')
        nil
      end

      # --- permissions -------------------------------------------------------

      def on_control_request(message)
        id = message['request_id']
        request = message['request'].is_a?(Hash) ? message['request'] : {}
        unless id.is_a?(String) && !id.empty?
          notice('Claude Code sent a control request without an id; it was not answered.')
          return
        end
        unless request['subtype'] == 'can_use_tool'
          record('control_request_refused', 'subtype' => token(request['subtype']))
          deliver('type' => 'control_response', 'response' => { 'subtype' => 'error', 'request_id' => id, 'error' => 'not supported' })
          return
        end
        if @pending.key?(id)
          notice("Claude Code repeated permission request #{id}; the first one is still waiting for an answer.")
          return
        end
        if @answered.key?(id)
          notice("Claude Code repeated permission request #{id} after it was answered; the repeat was denied.")
          deliver(denial(id, 'console'))
          return
        end
        tool_use_id = request['tool_use_id']
        input = request['input']
        name = request['tool_name']
        # An allow carries back exactly the input shown, so a request whose
        # tool name or input cannot be shown exactly (text that is not UTF-8,
        # a number JSON cannot write) waits for the owner like any other but
        # can only be denied. It is registered before it is shown, so a stop
        # denies it whatever becomes of its event.
        exact = name.is_a?(String) && input.is_a?(Hash) && exact?(name) && exact?(input)
        @pending[id] = { 'tool_use_id' => tool_use_id, 'tool_name' => name, 'input' => input, 'exact' => exact }
        emit('permission_request', 'request_id' => id, 'tool_use_id' => tool_use_id, 'tool_name' => name,
                                   'display_name' => request['display_name'], 'description' => request['description'],
                                   'input' => input, 'exact' => exact)
        record('permission_request', 'request_id' => token(id), 'tool_name' => token(name), 'exact' => exact)
        if @stopped
          resolve(id, 'deny', by: 'console_stop')
        elsif @turn_foreign
          resolve(id, 'deny', by: 'console', why: 'it belongs to a turn the console did not start')
        end
      end

      def resolve(id, decision, by:, why: nil)
        request = @pending.delete(id)
        @answered[id] = decision
        @answer_for_tool[request['tool_use_id']] = decision if request['tool_use_id'].is_a?(String)
        emit('permission_answered', 'request_id' => id, 'decision' => decision, 'by' => by)
        record('permission_answer', 'request_id' => token(id), 'tool_name' => token(request['tool_name']), 'decision' => decision, 'by' => by)
        notice("The console denied #{request['tool_name'] || 'a tool'} because #{why}.") if why
        if decision == 'allow'
          deliver('type' => 'control_response',
                  'response' => { 'subtype' => 'success', 'request_id' => id,
                                  'response' => { 'behavior' => 'allow', 'updatedInput' => request['input'] } })
        else
          deliver(denial(id, by))
        end
      end

      def denial(id, by)
        { 'type' => 'control_response',
          'response' => { 'subtype' => 'success', 'request_id' => id,
                          'response' => { 'behavior' => 'deny', 'message' => DENY_MESSAGES.fetch(by) } } }
      end

      # Not measured on 2.1.303; if Claude Code withdraws a request, it is
      # denied so that no stale request can be answered with allow later.
      def on_cancel(message)
        id = message['request_id']
        resolve(id, 'deny', by: 'console', why: 'Claude Code withdrew the request') if @pending.key?(id)
      end

      # --- control responses and mode ---------------------------------------

      def on_control_response(message)
        response = message['response'].is_a?(Hash) ? message['response'] : {}
        id = response['request_id']
        if @mode_request && id == @mode_request['id']
          on_mode_answer(response)
        elsif @answered.key?(id)
          # Claude Code writes the console's own permission answers back; they
          # are recorded and change nothing.
          record('permission_echo', 'request_id' => token(id), 'behavior' => token(response.dig('response', 'behavior')))
        elsif @interrupt_ids.key?(id)
          notice('Claude Code could not interrupt the turn.') unless response['subtype'] == 'success'
        else
          notice('Claude Code sent a control response the console did not ask for; it changed nothing.')
        end
      end

      def request_mode_change(target, by:)
        id = next_id('km-mode')
        need_status = target == ASKING_WORD && !@mode_word.nil? && @mode_word != ASKING_WORD
        @mode_request = { 'id' => id, 'target' => target, 'need_status' => need_status, 'echoed' => false, 'by' => by }
        record('mode_request', 'target' => target, 'by' => by)
        deliver('type' => 'control_request', 'request_id' => id,
                'request' => { 'subtype' => 'set_permission_mode', 'mode' => target == ASKING_WORD ? 'manual' : target })
      end

      def on_mode_answer(response)
        request = @mode_request
        word = response.dig('response', 'mode')
        unless response['subtype'] == 'success' && word.is_a?(String)
          @mode_request = nil
          @confirmed = nil
          record('mode_refused', 'target' => request['target'])
          notice('Claude Code did not confirm the mode change; choose the mode again.')
          return
        end
        report_mode(word, 'echo')
        if word != request['target']
          @mode_request = nil
          @confirmed = nil
          notice("Claude Code reported mode #{word} after the console asked for #{request['target']}; messages wait until a mode is confirmed.")
        elsif request['need_status']
          # Back from a mode that does not ask: the status report must agree too.
          request['echoed'] = true
        else
          @confirmed = word
          @mode_request = nil
        end
      end

      def report_mode(word, source)
        emit('mode', 'word' => word, 'asking' => word == ASKING_WORD, 'source' => source)
        return if word == @mode_word
        cause = @mode_request && word == @mode_request['target'] ? @mode_request['by'] : 'cli'
        record('mode', 'word' => token(word), 'source' => source, 'cause' => cause)
        @mode_word = word
      end

      def expected_words
        [@confirmed, @mode_request && @mode_request['target']].compact
      end

      def mismatch(reported)
        emit('mode_mismatch', 'expected' => @confirmed, 'reported' => reported)
        record('mode_mismatch', 'expected' => token(@confirmed), 'reported' => token(reported))
        @confirmed = nil
        interrupt_turn('mode_mismatch')
        # Bring the child back to the asking mode rather than leave it in an
        # unconfirmed one; messages wait until the CLI confirms.
        request_mode_change(ASKING_WORD, by: 'console') unless @mode_request || @stopped || @exited
      end

      # --- stream ------------------------------------------------------------

      def on_system(message)
        word = message['permissionMode']
        case message['subtype']
        when 'init'
          note_session_id(message['session_id'])
          unless @turn_open
            @turn_open = true
            @turn_replayed = @turn_foreign = false
          end
          if word.is_a?(String)
            report_mode(word, 'init')
            mismatch(word) if @confirmed.nil? || !expected_words.include?(word)
          else
            mismatch(nil)
          end
        when 'status'
          return unless word.is_a?(String)
          report_mode(word, 'status')
          if @mode_request && @mode_request['echoed'] && word == @mode_request['target']
            @confirmed = word
            @mode_request = nil
          elsif @confirmed && !expected_words.include?(word)
            mismatch(word)
          end
        when 'informational'
          notice("Claude Code: #{message['content']}") if message['content'].is_a?(String)
        end
      end

      def on_assistant(message)
        content = message.dig('message', 'content')
        return unless content.is_a?(Array)
        content.each do |block|
          next unless block.is_a?(Hash)
          case block['type']
          when 'text'
            emit('assistant_text', 'text' => block['text'].to_s)
          when 'tool_use'
            @tool_names[block['id']] = block['name'] if block['id'].is_a?(String)
            emit('tool_use', 'tool_use_id' => block['id'], 'name' => block['name'], 'input' => block['input'])
          when 'thinking', 'redacted_thinking'
            nil
          else
            notice("Claude Code sent assistant content of type #{block['type'].to_s[0, 64]}, which the console does not show.")
          end
        end
      end

      def on_user(message)
        content = message.dig('message', 'content')
        marked = message['isSynthetic'] || !message['origin'].nil?
        if !marked && content.is_a?(Array) && content.any? { |b| b.is_a?(Hash) && b['type'] == 'tool_result' }
          content.each do |block|
            if block.is_a?(Hash) && block['type'] == 'tool_result'
              on_tool_result(block, message['tool_result_meta'])
            else
              notice("Claude Code added to a tool result: #{user_text([block]) || as_text(block)}")
            end
          end
          return
        end
        text = user_text(content)
        if message['isReplay'] == true && !marked && text && consume_replay(text)
          @turn_open = @turn_replayed = true
          return
        end
        foreign(message, text || as_text(content))
      end

      def as_text(value)
        JSON.generate(scrub(value), max_nesting: false)
      rescue StandardError
        "(#{value.class} content the console cannot quote)"
      end

      def user_text(content)
        return content if content.is_a?(String)
        return nil unless content.is_a?(Array) && content.length == 1
        block = content.first
        block['text'] if block.is_a?(Hash) && block['type'] == 'text' && block['text'].is_a?(String)
      end

      # The oldest unechoed message must come back first. Only a message that
      # an interrupt may have cancelled can be passed over.
      def consume_replay(text)
        index = @unreplayed.index { |m| m['text'] == text }
        return false unless index && @unreplayed.first(index).all? { |m| m['cancellable'] }
        @unreplayed.shift(index + 1)
        notice('An earlier message was not echoed back by Claude Code; it was probably cancelled by the interrupt.') if index.positive?
        true
      end

      # The turn is marked and interrupted before it is shown, so neither
      # depends on quoting what it said.
      def foreign(message, text)
        @turn_open = @turn_foreign = true
        record('foreign_turn', 'synthetic' => message['isSynthetic'] ? true : false,
                               'replay' => message['isReplay'] == true, 'origin' => !message['origin'].nil?)
        interrupt_turn('foreign_turn')
        emit('foreign_turn', 'text' => text, 'origin' => message['origin'])
      end

      def on_tool_result(block, meta)
        id = block['tool_use_id']
        entry = Array(meta).find { |m| m.is_a?(Hash) && m['id'] == id }
        decision = entry.is_a?(Hash) && entry['permission_decision'].is_a?(Hash) ? entry['permission_decision'] : {}
        source = decision['source']
        ours = @answer_for_tool[id]
        by_page = (source == 'user_temporary' && ours == 'allow') || (source == 'user_reject' && ours == 'deny')
        emit('tool_result', 'tool_use_id' => id, 'is_error' => block['is_error'] == true, 'content' => block['content'],
                            'decision' => decision['decision'], 'decision_source' => source, 'decided_by_page' => by_page)
        record('permission_decision', 'tool_use_id' => token(id), 'tool_name' => token(@tool_names[id]),
                                      'decision' => token(decision['decision']), 'source' => token(source),
                                      'reason_type' => token(decision['reason_type']), 'decided_by_page' => by_page)
      end

      def on_result(message)
        if @turn_open && !@turn_replayed && !@turn_foreign && !@unreplayed.empty?
          # A turn ended without echoing the message it answered (a refused
          # command): count the oldest live message, and any cancellable ones
          # queued before it, as answered, so no message can wait forever.
          live = @unreplayed.index { |m| !m['cancellable'] }
          @unreplayed.shift(live ? live + 1 : 1)
          notice('Claude Code ended a turn without echoing the message back; the console counts that message as answered.')
        end
        # A request still open stays pending: only the owner or a stop answers it.
        @turn_open = @turn_replayed = @turn_foreign = false
        emit('turn_end', 'subtype' => message['subtype'], 'is_error' => message['is_error'] == true)
      end

      def note_session_id(value)
        return unless value.is_a?(String) && value != @session_id
        @session_id = value
        record('session_id', 'session_id' => token(value))
      end

      def interrupt_turn(reason)
        @unreplayed.each { |m| m['cancellable'] = true }
        id = next_id('km-int')
        @interrupt_ids[id] = true
        record('interrupt', 'reason' => reason)
        deliver('type' => 'control_request', 'request_id' => id, 'request' => { 'subtype' => 'interrupt' })
      end

      # --- accepting ---------------------------------------------------------

      def turn_in_progress?
        @turn_open || @unreplayed.any? { |m| !m['cancellable'] }
      end

      def refusal
        return 'stopped' if @stopped || @exited
        return 'memory_cap' if @capped
        return 'mode_unconfirmed' if @confirmed.nil? || @mode_request || @mode_word != @confirmed
        return 'turn_in_progress' if turn_in_progress?
        nil
      end

      def refresh_accepting(force: false)
        reason = refusal
        value = reason.nil?
        return if !force && value == @accepting && reason == @accept_reason
        @accepting = value
        @accept_reason = reason
        emit('accepting', 'value' => value, 'reason' => reason)
      end

      # --- events and log ----------------------------------------------------

      # An event is kept only once it is known to serialize, so no event can
      # make the replay of the session fail.
      def emit(kind, fields)
        event = { 'seq' => @seq + 1, 'at' => timestamp, 'kind' => kind }.merge(scrub(fields)).freeze
        size = JSON.generate(event, max_nesting: false).bytesize
        @seq += 1
        @events << event
        @bytes += size
        check_cap
        event
      end

      def check_cap
        return if @capped || @bytes <= @cap
        @capped = true
        record('memory_cap', 'bytes' => @bytes)
        emit('notice', 'text' => 'The console reached its memory limit for this session: new messages are refused and the turn in progress is interrupted. ' \
                                 'Events that still arrive are recorded. Stop the console and start it again to continue.')
        interrupt_turn('memory_cap') if @started && !@exited
        refresh_accepting
      end

      # One console-log line. Values are tokens, booleans and numbers only: no
      # tool input, message text or anything else the stream said at length.
      def record(event, fields)
        @log.call({ 'at' => timestamp, 'event' => event }.merge(fields))
      rescue StandardError
        return if @log_failed
        @log_failed = true
        emit('notice', 'text' => 'The console log could not be written; the session continues unrecorded there.')
      end

      def token(value)
        value.is_a?(String) && LOG_TOKEN.match?(value) ? value : nil
      end

      def timestamp
        now = @clock.call
        now.respond_to?(:getutc) ? now.getutc.iso8601(3) : now.to_s
      end

      def next_id(prefix)
        @counter += 1
        "#{prefix}-#{@counter}-#{SecureRandom.hex(4)}"
      end

      def exit_code(status)
        return status if status.is_a?(Integer) || status.nil?
        return status.exitstatus if status.respond_to?(:exitstatus) && status.exitstatus
        return "signal #{status.termsig}" if status.respond_to?(:termsig) && status.termsig
        status.to_s
      end

      def utf8(text)
        return nil unless text.is_a?(String)
        value = text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8)
        value.valid_encoding? ? value : nil
      end

      # True when JSON can carry the value back unchanged, through the page's
      # JavaScript parse too, which rounds integers beyond 2^53.
      def exact?(value)
        case value
        when String then value.valid_encoding?
        when Integer then value.abs <= 2**53 - 1
        when Float then value.finite?
        when Array then value.all? { |v| exact?(v) }
        when Hash then value.all? { |k, v| exact?(k) && exact?(v) }
        else true
        end
      end

      # Events are shown verbatim, so what JSON cannot write — invalid bytes,
      # a number outside the double range (1e400 parses as Infinity) — is
      # replaced by visible text rather than letting one value make every
      # later replay unserializable.
      def scrub(value)
        case value
        when String
          utf = value.encoding == Encoding::UTF_8 ? value : value.dup.force_encoding(Encoding::UTF_8)
          utf.valid_encoding? ? utf : utf.scrub("�")
        when Float then value.finite? ? value : value.to_s
        when Array then value.map { |v| scrub(v) }
        when Hash then value.to_h { |k, v| [scrub(k), scrub(v)] }
        else value
        end
      end
    end
  end
end
