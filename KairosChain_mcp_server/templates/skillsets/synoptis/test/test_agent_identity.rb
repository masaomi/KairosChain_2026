# frozen_string_literal: true

# ToolHelpers#resolve_agent_id — the one place a recorded action's actor is named.
#
# R4 (2026-08-01) found this method had no test at all: reverting it left every
# suite green. Two placeholder returns had already been tried and both collapsed
# identity, so the behaviour under test here is that there is no placeholder.
#
#   'unknown'  non-empty, so every attributability check passed and all anchors
#              in that state shared one attester id
#   nil        became '' at the comparison sites, and '' matches more records
#              than 'unknown' did (a proof that is not found yields nil.to_s)
#
# Ruling of 2026-08-02: raise instead, so a blank identity is unrepresentable at
# the point of production rather than guarded at each of five comparison sites.

project_root = File.expand_path('../../../..', __dir__)
mmp_lib = File.join(project_root, 'KairosChain_mcp_server', 'templates', 'skillsets', 'mmp', 'lib')
$LOAD_PATH.unshift(mmp_lib) unless $LOAD_PATH.include?(mmp_lib)
synoptis_lib = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(synoptis_lib) unless $LOAD_PATH.include?(synoptis_lib)

require 'synoptis/tool_helpers'

$pass = 0
$fail = 0

def assert(condition, message)
  if condition
    $pass += 1
    puts "  PASS: #{message}"
  else
    $fail += 1
    puts "  FAIL: #{message}"
  end
end

def section(title)
  puts "\n#{'=' * 60}"
  puts "SECTION: #{title}"
  puts '=' * 60
end

# A host that yields whatever identity the case under test needs. Only
# mmp_identity is stubbed; resolve_agent_id itself is the shipped method.
class IdentityHost
  include Synoptis::ToolHelpers

  def initialize(&block)
    @block = block
  end

  def mmp_identity
    @block.call
  end
end

def resolve(&block)
  IdentityHost.new(&block).resolve_agent_id
end

def raises_unattributable?(&block)
  resolve(&block)
  false
rescue Synoptis::UnattributableAgentError
  true
end

# ============================================================
section '1. A resolvable identity is returned unchanged'
# ============================================================

id = resolve { Struct.new(:instance_id).new('anchor-instance-0001') }
assert id == 'anchor-instance-0001', 'a resolvable instance_id is returned as-is'

# ============================================================
section '2. No blank identity is ever produced'
# ============================================================

[[nil, 'nil'], ['', 'empty string'], ['   ', 'whitespace only']].each do |value, label|
  assert raises_unattributable? { Struct.new(:instance_id).new(value) },
         "#{label} raises UnattributableAgentError instead of being returned"
end

assert raises_unattributable? { raise NameError, 'uninitialized constant MMP::VERSION' },
       'a partially loaded MMP raises UnattributableAgentError, not a placeholder'

assert raises_unattributable? { raise StandardError, 'registry unavailable' },
       'any other failure to resolve raises UnattributableAgentError'

# ============================================================
section '3. The placeholders that collapsed identity are not reachable'
# ============================================================

# These are the two values the comparison sites treated as authority. Neither can
# come out of resolve_agent_id now; the assertions state which comparison each one
# used to satisfy, so a revision that reintroduces a placeholder fails here.
begin
  produced = []
  [nil, '', '   ', 'x'].each do |value|
    produced << (resolve { Struct.new(:instance_id).new(value) } rescue :raised)
  end
  assert !produced.include?('unknown'),
         "'unknown' is unreachable (RevocationManager authorises on revoker_id == attester_id)"
  assert produced.none? { |p| p.is_a?(String) && p.strip.empty? },
         "'' is unreachable (ChallengeManager compares against envelope&.attester_id.to_s)"
  assert produced.count(:raised) == 3, 'exactly the three blank inputs raised'
  assert produced.last == 'x', 'a non-blank identity still passes through'
end

# ============================================================
section '4. The error carries why, not just that'
# ============================================================

begin
  resolve { raise NameError, 'uninitialized constant MMP::VERSION' }
rescue Synoptis::UnattributableAgentError => e
  assert e.message.include?('refusing to record'), 'the message states the refusal'
  assert e.message.include?('NameError'), 'the message keeps the underlying cause'
  assert Synoptis::UnattributableAgentError < StandardError,
         'the error is a StandardError so Protocol#handle turns it into an error response'
end

# ============================================================
puts "\n#{'=' * 60}"
puts "FINAL RESULTS: #{$pass} passed, #{$fail} failed"
puts '=' * 60

exit(1) if $fail > 0
