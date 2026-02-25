// === Auth ===
export interface User {
  id: string;
  name: string;
  email: string;
  avatar_url?: string;
  subscription_status: 'free' | 'premium' | 'enterprise';
  created_at: string;
  updated_at: string;
}

// === Echoria 5-Axis Affinity System ===
export interface Affinity {
  tiara_trust: number;           // 0-100: Bond with Tiara
  logic_empathy_balance: number; // -50 to +50: Analytical ↔ Empathetic
  name_memory_stability: number; // 0-100: Identity coherence
  authority_resistance: number;  // -50 to +50: Compliant ↔ Resistant
  fragment_count: number;        // 0+: Collected カケラ
  [key: string]: number;
}

export interface AffinitySummary {
  tiara_relationship: 'distant' | 'cautious' | 'open' | 'intimate' | 'merged';
  thinking_style: 'analytical' | 'empathetic';
  identity_stability: 'fragmented' | 'uncertain' | 'forming' | 'stable';
  authority_stance: 'compliant' | 'resistant';
  fragments_collected: number;
  total_resonance: number;
}

// === Echo ===
export interface Echo {
  id: string;
  user_id: string;
  name: string;
  status: 'embryo' | 'growing' | 'crystallized';
  personality: EchoPersonality;
  avatar_url?: string;
  created_at: string;
  updated_at: string;
}

export interface EchoPersonality {
  traits?: Record<string, unknown>;
  affinities?: Partial<Affinity>;
  memories?: string[];
  skills?: string[];
  primary_archetype?: string;
  secondary_traits?: string[];
  character_description?: string;
  crystallized_at?: string;
  strengths?: string[];
  growth_areas?: string[];
  story_arc?: {
    chapter: string;
    scenes_experienced: number;
    journey_completion: number;
    resonance_score?: number;
  };
}

// === Story Beacons ===
export interface StoryBeacon {
  id: number;
  chapter: string;
  order: number;
  title: string;
  content: string;
  tiara_dialogue?: string;
  choices: BeaconChoice[];
  metadata?: {
    location?: string;
    beacon_id?: string;
    is_chapter_end?: boolean;
  };
}

export interface BeaconChoice {
  choice_id: string;
  choice_text: string;
  narrative_result?: string;
  affinity_delta: Partial<Affinity>;
  next_beacon_id?: number;
}

// === Story Sessions ===
export interface StorySession {
  id: string;
  chapter: string;
  scene_count: number;
  affinity: Affinity;
  status: 'active' | 'paused' | 'completed';
  created_at: string;
  current_beacon?: StoryBeacon;
  recent_scenes?: StoryScene[];
  affinity_summary?: AffinitySummary;
}

// === Story Scenes ===
export interface StoryScene {
  id: number;
  order: number;
  type: 'beacon' | 'generated' | 'fallback';
  narrative: string;
  echo_action?: string;
  user_choice?: string;
  decision_actor?: 'player' | 'echo' | 'system';
  affinity_impact?: Partial<Affinity>;
  created_at: string;
}

// === Choice Response (after making a choice) ===
export interface ChoiceResponse {
  scene: StoryScene;
  session: {
    id: string;
    chapter: string;
    scene_count: number;
    affinity: Affinity;
    status: string;
    affinity_summary: AffinitySummary;
  };
  next_choices: BeaconChoice[];
  chapter_end?: boolean;
  crystallization_available?: boolean;
  beacon_progress?: number;
}

// === Chat (post-crystallization) ===
export interface EchoMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  created_at: string;
}

export interface EchoConversation {
  id: string;
  echo_id: string;
  messages: EchoMessage[];
  created_at: string;
  updated_at: string;
}

// === API Error ===
export interface ApiError {
  error: string;
  details?: string;
  session_id?: string;
}
