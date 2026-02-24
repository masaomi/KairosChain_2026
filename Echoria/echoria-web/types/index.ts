export interface User {
  id: string;
  name: string;
  email: string;
  createdAt: string;
  updatedAt: string;
}

export interface Affinity {
  courage: number;
  wisdom: number;
  compassion: number;
  ambition: number;
  curiosity: number;
  tiaraAffinity: number;
  [key: string]: number;
}

export interface KeyMoment {
  id: string;
  description: string;
  timestamp: string;
  affinityChanges: Record<string, number>;
}

export interface Echo {
  id: string;
  userId: string;
  name: string;
  status: 'embryo' | 'growing' | 'crystallized';
  affinity: Affinity;
  storyProgress: number;
  keyMoments?: KeyMoment[];
  createdAt: string;
  updatedAt: string;
}

export interface Choice {
  id: string;
  text: string;
  consequence?: string;
  affinityImpact?: Record<string, number>;
}

export interface StoryScene {
  id: string;
  title?: string;
  narrative: string;
  tiaraDialogue?: string;
  echoAction?: string;
  choices: Choice[];
  mood?: 'dark' | 'peaceful' | 'tense' | 'mystical';
  affinityChanges?: Record<string, number>;
  timestamp: string;
}

export interface StorySession {
  id: string;
  echoId: string;
  currentSceneId: string;
  visitedScenes: string[];
  decisions: Array<{
    sceneId: string;
    choiceId: string;
    timestamp: string;
  }>;
  createdAt: string;
  updatedAt: string;
}

export interface EchoMessage {
  id: string;
  role: 'user' | 'echo' | 'tiara';
  content: string;
  timestamp: string;
}

export interface EchoConversation {
  id: string;
  echoId: string;
  messages: EchoMessage[];
  createdAt: string;
  updatedAt: string;
}

export interface ApiResponse<T> {
  success: boolean;
  data: T;
  message?: string;
}
