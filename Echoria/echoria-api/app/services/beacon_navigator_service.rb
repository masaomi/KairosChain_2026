# Manages beacon-to-beacon navigation within a story chapter.
#
# Determines which beacon comes next based on the current beacon,
# player choices, and session state. Handles both linear progression
# and choice-driven branching.
#
class BeaconNavigatorService
  class BeaconNotFoundError < StandardError; end

  def initialize(story_session)
    @session = story_session
    @chapter = story_session.chapter
  end

  # Returns the first beacon of the chapter
  def first_beacon
    StoryBeacon.in_chapter(@chapter).ordered.first
  end

  # Returns the current beacon for the session
  def current_beacon
    @session.current_beacon || first_beacon
  end

  # Determines the next beacon after a choice is made.
  # Priority: 1) choice's next_beacon_id, 2) sequential beacon_order
  def next_beacon(selected_choice = nil)
    # If the choice explicitly points to a next beacon
    if selected_choice.is_a?(Hash) && selected_choice["next_beacon_id"].present?
      beacon = StoryBeacon.find_by(id: selected_choice["next_beacon_id"])
      return beacon if beacon
    end

    # Default: advance to next beacon_order in this chapter
    current = current_beacon
    return nil unless current

    StoryBeacon.in_chapter(@chapter)
               .where("beacon_order > ?", current.beacon_order)
               .ordered
               .first
  end

  # Advance the session to the next beacon
  def advance!(selected_choice = nil)
    target = next_beacon(selected_choice)
    return nil unless target

    @session.update!(current_beacon_id: target.id)
    target
  end

  # Check if current beacon is the last in the chapter
  def chapter_end?
    current = current_beacon
    return false unless current

    metadata = current.metadata || {}
    return true if metadata["is_chapter_end"] == true

    # Also check if no more beacons exist after this one
    !StoryBeacon.in_chapter(@chapter)
                .where("beacon_order > ?", current.beacon_order)
                .exists?
  end

  # Returns all beacons in this chapter, ordered
  def chapter_beacons
    StoryBeacon.in_chapter(@chapter).ordered
  end

  # Returns the number of beacons in this chapter
  def total_beacons
    chapter_beacons.count
  end

  # Returns progress through the chapter's beacons (0.0 to 1.0)
  def beacon_progress
    current = current_beacon
    return 0.0 unless current

    total = total_beacons
    return 0.0 if total.zero?

    current.beacon_order.to_f / total
  end

  # Validates that a choice index is valid for the current beacon
  def valid_choice?(choice_index)
    beacon = current_beacon
    return false unless beacon
    return false unless beacon.choices.is_a?(Array)

    choice_index.between?(0, beacon.choices.length - 1)
  end

  # Gets the choice data for a given index from the current beacon
  def choice_at(index)
    beacon = current_beacon
    return nil unless beacon && beacon.choices.is_a?(Array)
    return nil unless index.between?(0, beacon.choices.length - 1)

    beacon.choices[index]
  end

  # Creates a beacon scene (fixed story content from the beacon itself)
  def create_beacon_scene!
    beacon = current_beacon
    return nil unless beacon

    @session.story_scenes.create!(
      scene_order: @session.scene_count + 1,
      scene_type: :beacon,
      beacon_id: beacon.id,
      narrative: beacon.content,
      echo_action: beacon.tiara_dialogue,
      decision_actor: :system,
      affinity_delta: {}
    ).tap do
      @session.update!(scene_count: @session.scene_count + 1)
    end
  end
end
