#!/usr/bin/env ruby
# frozen_string_literal: true

# Drives the two mechanical parts of stage 3 — pulling the code out of a reply,
# and running it once — without calling any model.
#
# Every assertion here is paired with a falsification: the check is shown going
# red against a case it must reject. A green check that has never been shown to
# go red is not evidence.
#
# Usage, from the project root:
#   ruby KairosChain_mcp_server/templates/skillsets/minimum_nomic/test/test_propose_metric.rb

require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../bin/propose_metric'

FAILURES = []
CHECKS = []

def check(name)
  CHECKS << name
  ok = yield
  FAILURES << name unless ok
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
end

# A corpus small enough to run against in a fraction of a second, shaped like the
# real one: one game directory holding records/.
def with_corpus
  Dir.mktmpdir('nomic_test_corpus_') do |root|
    recs = File.join(root, 'g1', 'records')
    FileUtils.mkdir_p(recs)
    File.write(File.join(recs, 'utterances.jsonl'),
               [{ 'seq' => 1, 'player' => 'A', 'text' => 'I propose Rule 201.', 'in_public_log' => true },
                { 'seq' => 2, 'player' => 'B', 'text' => 'I vote in favor.', 'in_public_log' => true }]
                 .map { |h| JSON.generate(h) }.join("\n") + "\n")
    File.write(File.join(recs, 'lineup.jsonl'),
               JSON.generate({ 'analysts' => [{ 'id' => 'a', 'adapter' => 'codex', 'model' => 'm' }] }) + "\n")
    yield root
  end
end

puts 'extract_code'

check 'takes the fenced block and its language' do
  r = extract_code("prose\n\n```python\nprint(1)\n```\n\nmore prose\n")
  r['lang'] == 'python' && r['code'] == "print(1)\n" && r['block_count'] == 1
end

check 'takes the LONGEST block when there are several' do
  reply = "```python\nprint(1)\n```\n\n```ruby\nputs 1\nputs 2\nputs 3\n```\n"
  r = extract_code(reply)
  r['block_count'] == 2 && r['lang'] == 'ruby' && r['code'].lines.length == 3
end

# Falsification: an unfenced reply must NOT be salvaged into code. Treating the
# whole reply as a submission is the repair this stage refuses.
check 'REFUSES to salvage a reply with no fence' do
  r = extract_code("Here is my procedure: count the hedges, divide by turns.\n")
  r['block_count'].zero? && r['code'].nil?
end

check 'a fence with no language is captured, with lang empty' do
  r = extract_code("```\nprint(1)\n```\n")
  r['block_count'] == 1 && r['lang'] == '' && r['code'] == "print(1)\n"
end

check 'nil reply yields no code' do
  extract_code(nil)['code'].nil?
end

puts 'run_submission'

with_corpus do |corpus|
  check 'a working submission is recorded as ran, with its output' do
    r = run_submission("import os,json\nprint(len(os.listdir('.')))\n", 'python', corpus, 30)
    r['outcome'] == 'ran' && r['exit_status'].zero? && r['stdout'].strip == '1'
  end

  check 'the submission can actually read the corpus it was given' do
    code = "import json\nrows=[json.loads(l) for l in open('g1/records/utterances.jsonl')]\nprint(len(rows))\n"
    r = run_submission(code, 'python', corpus, 30)
    r['outcome'] == 'ran' && r['stdout'].strip == '2'
  end

  # Falsification: a submission that crashes must NOT come back as "ran". This is
  # the case the R5 reviewers said v0.6's prose could not decide — an exception
  # leaves output on stderr and the process terminates, so a definition resting on
  # "finished and left some output" would score it as a success. Here the decision
  # is the exit status, and this check is what holds it there.
  check 'a crashing submission is failed, NOT ran, even though it left output' do
    r = run_submission("raise SystemExit(3)\n", 'python', corpus, 30)
    r['outcome'] == 'failed' && r['exit_status'] == 3
  end

  check 'a syntax error is failed and its stderr is kept' do
    r = run_submission("def (\n", 'python', corpus, 30)
    r['outcome'] == 'failed' && r['stderr'].include?('Error')
  end

  # Falsification: an empty submission that exits cleanly is "ran". Silence is not
  # failure — the stage records what was printed, it does not require anything to
  # be printed. Pairs with the crash check above: together they show the boundary
  # sits at exit status and not at whether output appeared.
  check 'a submission that prints nothing but exits cleanly is ran' do
    r = run_submission("pass\n", 'python', corpus, 30)
    r['outcome'] == 'ran' && r['stdout'].empty?
  end

  check 'a non-terminating submission is cut off, not ran and not failed' do
    r = run_submission("while True:\n    pass\n", 'python', corpus, 2)
    r['outcome'] == 'cut_off' && r['seconds'] >= 2
  end

  check 'a submission that fills the pipe does not deadlock the wait' do
    r = run_submission("print('x' * 5_000_000)\n", 'python', corpus, 30)
    r['outcome'] == 'ran' && r['stdout_truncated'] && r['stdout_bytes'] > OUTPUT_CAP
  end

  check 'an unsupported fence language is not run' do
    r = run_submission("SELECT 1;\n", 'sql', corpus, 30)
    r['outcome'] == 'not_run' && r['reason'].include?('sql')
  end

  check 'ruby submissions run too' do
    r = run_submission("puts Dir.children('.').length\n", 'ruby', corpus, 30)
    r['outcome'] == 'ran' && r['stdout'].strip == '1'
  end

  # Falsification: the corpus handed to the submission must be a COPY. A
  # submission that deletes everything must leave the original intact.
  check 'a destructive submission cannot touch the original corpus' do
    r = run_submission("import shutil,os\nfor d in os.listdir('.'): shutil.rmtree(d)\nprint('gone')\n",
                       'python', corpus, 30)
    r['outcome'] == 'ran' &&
      File.exist?(File.join(corpus, 'g1', 'records', 'utterances.jsonl'))
  end

  # Falsification: no credential from this session may reach the submission.
  check 'no environment variable leaks into the submission' do
    key = 'NOMIC_TEST_SECRET_DO_NOT_LEAK'
    ENV[key] = 'leaked'
    begin
      r = run_submission("import os\nprint(os.environ.get('#{key}', 'ABSENT'))\n" \
                         "print(len([k for k in os.environ if 'KEY' in k or 'TOKEN' in k]))\n",
                         'python', corpus, 30)
      r['outcome'] == 'ran' && r['stdout'].lines.map(&:strip) == %w[ABSENT 0]
    ensure
      ENV.delete(key)
    end
  end
end

puts
puts "#{CHECKS.length - FAILURES.length}/#{CHECKS.length} checks passed"
unless FAILURES.empty?
  puts "failed: #{FAILURES.join(', ')}"
  exit 1
end
