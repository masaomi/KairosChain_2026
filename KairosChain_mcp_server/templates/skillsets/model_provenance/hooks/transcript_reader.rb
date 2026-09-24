# frozen_string_literal: true

require 'json'

# Claude Code layer only (design v0.3 INV-2). This file knows Claude Code's
# transcript format and is deliberately outside lib/, which is the directory a
# KairosChain SkillSet load puts on $LOAD_PATH. The hook script requires it by
# relative path; nothing on the KairosChain side can reach it by name.
module ModelProvenanceHook
  module TranscriptReader
    # One API response: every assistant record sharing a requestId, attributed
    # to the model of its last record, so a request carried on by fallback
    # counts once, for the model that finished it.
    Response = Struct.new(:request_id, :model, :offset, :at, :text, keyword_init: true)

    # Read complete lines from byte offset `from`. A trailing line without a
    # newline is not consumed: it is a record still being written.
    #
    # A response is emitted when its group closes, not when it opens. In the
    # first observed fallback the flagged request's first record precedes the
    # marker inside the same requestId; emitting at open would classify that
    # response before the marker was seen.
    #
    # Returns { events:, end_offset:, tail_offset:, torn_tail:, unparsable: },
    # where each event is [kind, payload, offset] and tail_offset is where the
    # last response group began (nil when there is none).
    # `after_response` carries across reads whether the transcript already
    # holds a response, so a resume that is the first new record after the
    # cursor is still recognised as starting a run.
    def self.read(path, from: 0, scope: :main, after_response: false)
      data = File.binread(path)
      from = 0 if from > data.bytesize
      chunk = data.byteslice(from, data.bytesize - from) || ''
      last_nl = chunk.rindex("\n")
      complete = last_nl ? chunk.byteslice(0, last_nl + 1) : ''
      torn = complete.bytesize < chunk.bytesize

      events = []
      unparsable = 0
      open = nil
      seen_response_since_run = after_response
      tail_offset = nil
      offset = from

      flush = lambda do
        next unless open

        events << [:response, open, open.offset]
        tail_offset = open.offset
        open = nil
      end

      complete.each_line do |line|
        line_offset = offset
        offset += line.bytesize
        next if line.strip.empty?

        record = begin
          JSON.parse(line)
        rescue JSON::ParserError
          unparsable += 1
          next
        end
        next unless record.is_a?(Hash)

        case record['type']
        when 'assistant'
          message = record['message'].is_a?(Hash) ? record['message'] : {}
          blocks = message['content'].is_a?(Array) ? message['content'] : []
          marker = blocks.find { |b| b.is_a?(Hash) && b['type'] == 'fallback' }
          if marker
            # A marker with its own requestId (the second observed case) closes
            # the response before it; one sharing the open group's requestId
            # (the first case) belongs inside that response.
            flush.call if open && open.request_id != record['requestId']
            events << [:marker, { from: marker.dig('from', 'model'), to: marker.dig('to', 'model'),
                                  at: record['timestamp'] }, line_offset]
          end
          # A record whose only content is the marker is not part of a response.
          next if marker && blocks.all? { |b| b.is_a?(Hash) && b['type'] == 'fallback' }

          model = message['model']
          request_id = record['requestId']
          # Harness-synthesised records (API errors, "No response requested.")
          # are not responses, including the ones that carry a requestId.
          next if model.nil? || model == '<synthetic>' || request_id.nil?

          text = blocks.select { |b| b.is_a?(Hash) && b['type'] == 'text' }
                       .map { |b| b['text'].to_s }.join
          if open && open.request_id == request_id
            open.model = model
            open.at = record['timestamp'] || open.at
            # The whole response's text, so the final-text check compares like
            # with like instead of accepting a prefix.
            open.text = [open.text, text].reject(&:empty?).join("\n")
          else
            flush.call
            open = Response.new(request_id: request_id, model: model, offset: line_offset,
                                at: record['timestamp'], text: text)
            seen_response_since_run = true
          end
        when 'user'
          text = user_text(record.dig('message', 'content'))
          next if text.nil?

          if scope == :main && text.lstrip.start_with?('<command-name>/model</command-name>')
            # A slash command is the whole message; a quoted tag inside other
            # text is not a model change. Subagents cannot run /model.
            flush.call
            events << [:user_switch, { at: record['timestamp'] }, line_offset]
          elsif scope == :subagent && seen_response_since_run && resume?(record)
            # A message from the coordinator or a peer after the agent has
            # answered is a resume (SendMessage): a new run, which starts on the
            # agent's declared model. Harness companion records (a Skill body,
            # an image caption), interruptions and the agent's own task
            # notifications are not resumes.
            flush.call
            events << [:run_start, { at: record['timestamp'] }, line_offset]
            seen_response_since_run = false
          end
        when 'system'
          if scope == :main && record['subtype'] == 'local_command' && record['content'].to_s.include?('Set model to')
            flush.call
            events << [:user_switch, { at: record['timestamp'] }, line_offset]
          end
        end
      end
      flush.call

      { events: events, end_offset: from + complete.bytesize, tail_offset: tail_offset,
        torn_tail: torn, unparsable: unparsable }
    end

    RESUME_ORIGINS = %w[coordinator peer].freeze

    def self.resume?(record)
      origin = record['origin']
      origin.is_a?(Hash) && RESUME_ORIGINS.include?(origin['kind']) && !record['turnCompanion']
    end

    # Text of a user record, or nil when it is a tool result rather than a message.
    def self.user_text(content)
      case content
      when String then content
      when Array
        return nil if content.any? { |b| b.is_a?(Hash) && b['type'] == 'tool_result' }

        content.select { |b| b.is_a?(Hash) && b['type'] == 'text' }.map { |b| b['text'].to_s }.join
      end
    end

    # Classify responses (design v0.3 § 3, "answered through automatic fallback").
    #
    # `state` carries across reads: 'last_model', 'last_at', 'anomaly'
    # ({kind, from, to}), 'pending_origin', 'run'. `switches` are PostModelSwitch
    # records ({'at', 'source', 'to'}), the documented source for model changes
    # that did not come from a fallback marker.
    #
    # Returns { state:, responses:, models: {model => n}, anomalies: [...],
    #           last_response: }, each anomaly being
    #           { kind: 'fallback'|'automatic'|'unexplained', from:, to:, responses: }.
    def self.classify(events, state: {}, switches: [])
      state = state.dup
      models = Hash.new(0)
      anomalies = {}
      responses = 0
      last_response = nil

      events.each do |kind, payload, _offset|
        case kind
        when :marker
          state['anomaly'] = { 'kind' => 'fallback', 'from' => payload[:from], 'to' => payload[:to] }
          state['pending_origin'] = 'fallback'
        when :user_switch
          state['anomaly'] = nil
          state['pending_origin'] = 'user'
        when :run_start
          # A run start explains a model change, not the absence of one: a
          # resumed agent still on the fallback model is still in fallback.
          state['pending_origin'] = 'run_start'
          state['run'] = (state['run'] || 1) + 1
        when :response
          r = payload
          responses += 1
          models[r.model] += 1
          last_response = r
          prev = state['last_model']
          anomaly = state['anomaly']

          if anomaly && r.model == anomaly['to']
            record_anomaly(anomalies, anomaly)
          elsif prev && r.model != prev
            origin = state['pending_origin'] || switch_origin(switches, state['last_at'], r)
            case origin
            when 'user', 'run_start'
              state['anomaly'] = nil
            when 'automatic'
              state['anomaly'] = { 'kind' => 'automatic', 'from' => prev, 'to' => r.model }
              record_anomaly(anomalies, state['anomaly'])
            else
              state['anomaly'] = { 'kind' => 'unexplained', 'from' => prev, 'to' => r.model }
              record_anomaly(anomalies, state['anomaly'])
            end
          elsif anomaly && r.model != anomaly['to']
            # Back on another model with no recorded change in between: the
            # anomalous stretch has ended.
            state['anomaly'] = nil
          end
          state['last_model'] = r.model
          state['last_at'] = r.at
          state['pending_origin'] = nil
        end
      end

      { state: state, responses: responses, models: models.to_h, anomalies: anomalies.values,
        last_response: last_response }
    end

    def self.record_anomaly(anomalies, anomaly)
      key = [anomaly['kind'], anomaly['from'], anomaly['to']]
      anomalies[key] ||= { kind: anomaly['kind'], from: anomaly['from'], to: anomaly['to'], responses: 0 }
      anomalies[key][:responses] += 1
    end

    # A PostModelSwitch record whose target is this response's model and whose
    # time falls between the previous response and this one. Hook-reported,
    # so it is the documented origin of the change.
    def self.switch_origin(switches, prev_at, response)
      at = response.at.to_s
      hit = switches.reverse.find do |s|
        s['to'] == response.model && s['at'].to_s <= at && (prev_at.nil? || s['at'].to_s > prev_at.to_s)
      end
      return nil unless hit

      hit['source'] == 'auto' ? 'automatic' : 'user'
    end
  end
end
