# frozen_string_literal: true

require 'json'

# Builds transcripts in the shape Claude Code 2.1.281 writes them: one JSON
# object per line, assistant records carrying message.model and requestId, one
# content block per record. Shapes are taken from the two fallback transcripts
# observed on 2026-09-24 (design v0.3 § 1), not invented.
class TranscriptFixture
  def initialize
    @lines = []
    @t = 0
  end

  def ts
    @t += 1
    format('2026-09-24T08:%02d:%02d.000Z', @t / 60, @t % 60)
  end

  def user(text)
    @lines << { 'type' => 'user', 'timestamp' => ts, 'message' => { 'role' => 'user', 'content' => text } }
    self
  end

  # A SendMessage resume as Claude Code writes it: the message carries an
  # `origin` naming who sent it (observed kinds: coordinator, peer).
  def resume(text, kind: 'coordinator')
    @lines << { 'type' => 'user', 'timestamp' => ts, 'isMeta' => true, 'origin' => { 'kind' => kind },
                'message' => { 'role' => 'user', 'content' => text } }
    self
  end

  # The agent's own background task finishing: also an `origin`, not a resume.
  def task_notification(text = '[SYSTEM NOTIFICATION - NOT USER INPUT] task done')
    resume(text, kind: 'task-notification')
  end

  # A harness companion record (a Skill body, an image caption).
  def companion(text = 'Base directory for this skill: /tmp/skill')
    @lines << { 'type' => 'user', 'timestamp' => ts, 'isMeta' => true, 'turnCompanion' => true,
                'sourceToolUseID' => 'toolu_x', 'message' => { 'role' => 'user', 'content' => text } }
    self
  end

  def tool_result
    @lines << { 'type' => 'user', 'timestamp' => ts,
                'message' => { 'role' => 'user', 'content' => [{ 'type' => 'tool_result', 'content' => 'ok' }] } }
    self
  end

  # One response: `records` assistant records sharing a requestId. The last
  # carries `text` when given.
  def response(model, request_id, records: 2, text: nil)
    records.times do |i|
      block = if i == records - 1 && text then { 'type' => 'text', 'text' => text }
              else { 'type' => 'thinking', 'thinking' => '' }
              end
      assistant(model, request_id, [block])
    end
    self
  end

  def assistant(model, request_id, blocks)
    @lines << { 'type' => 'assistant', 'timestamp' => ts, 'requestId' => request_id,
                'message' => { 'model' => model, 'content' => blocks } }
    self
  end

  def marker(from, to, request_id)
    assistant(to, request_id, [{ 'type' => 'fallback', 'from' => { 'model' => from }, 'to' => { 'model' => to } }])
  end

  def synthetic(request_id = nil)
    rec = { 'type' => 'assistant', 'timestamp' => ts, 'isApiErrorMessage' => true,
            'message' => { 'model' => '<synthetic>', 'content' => [{ 'type' => 'text', 'text' => '529 Overloaded' }] } }
    rec['requestId'] = request_id if request_id
    @lines << rec
    self
  end

  def model_command(to)
    @lines << { 'type' => 'system', 'subtype' => 'local_command', 'timestamp' => ts,
                'content' => "<local-command-stdout>Set model to #{to}</local-command-stdout>" }
    self
  end

  def raw(text)
    @lines << text
    self
  end

  def to_s
    @lines.map { |l| l.is_a?(String) ? l : JSON.generate(l) }.join("\n") + "\n"
  end

  def write(path)
    File.write(path, to_s)
    path
  end
end
