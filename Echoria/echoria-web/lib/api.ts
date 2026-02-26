import { getToken, removeToken } from './auth';
import {
  User,
  Echo,
  StorySession,
  StoryScene,
  ChoiceResponse,
  EchoConversation,
  EchoMessage,
  ChatPartner,
  StoryLogResponse,
  ChainStatus,
} from '@/types';

const API_BASE_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:3000/api/v1';

class ApiClient {
  private baseUrl: string;

  constructor(baseUrl: string = API_BASE_URL) {
    this.baseUrl = baseUrl;
  }

  private async request<T>(
    endpoint: string,
    options: RequestInit = {}
  ): Promise<T> {
    const url = `${this.baseUrl}${endpoint}`;
    const token = getToken();

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };

    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
    }

    const response = await fetch(url, {
      ...options,
      headers,
    });

    if (response.status === 401) {
      removeToken();
      if (typeof window !== 'undefined') {
        window.location.href = '/login';
      }
    }

    if (!response.ok) {
      let errorMessage = `HTTP ${response.status}`;
      try {
        const errorData = await response.json();
        errorMessage = errorData.error || errorData.message || errorMessage;
        // For conflict (existing session), include session_id
        if (response.status === 409 && errorData.session_id) {
          const err = new Error(errorMessage) as Error & { session_id?: string };
          err.session_id = errorData.session_id;
          throw err;
        }
      } catch (e) {
        if (e instanceof Error && (e as Error & { session_id?: string }).session_id) throw e;
      }
      throw new Error(errorMessage);
    }

    return response.json();
  }

  // === Auth ===
  async login(email: string, password: string): Promise<{ token: string; user: User }> {
    return this.request('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    });
  }

  async signup(
    name: string,
    email: string,
    password: string,
    password_confirmation: string
  ): Promise<{ token: string; user: User }> {
    return this.request('/auth/signup', {
      method: 'POST',
      body: JSON.stringify({ user: { name, email, password, password_confirmation } }),
    });
  }

  async googleAuth(token: string): Promise<{ token: string; user: User }> {
    return this.request('/auth/google', {
      method: 'POST',
      body: JSON.stringify({ token }),
    });
  }

  // Password reset
  async forgotPassword(email: string): Promise<{ message: string; token?: string }> {
    return this.request('/auth/forgot_password', {
      method: 'POST',
      body: JSON.stringify({ email }),
    });
  }

  async resetPassword(
    token: string,
    password: string,
    password_confirmation: string
  ): Promise<{ message: string }> {
    return this.request('/auth/reset_password', {
      method: 'POST',
      body: JSON.stringify({ token, password, password_confirmation }),
    });
  }

  // === Echoes ===
  async getEchoes(): Promise<Echo[]> {
    return this.request('/echoes');
  }

  async getEcho(id: string): Promise<Echo> {
    return this.request(`/echoes/${id}`);
  }

  async createEcho(name: string): Promise<Echo> {
    return this.request('/echoes', {
      method: 'POST',
      body: JSON.stringify({ echo: { name } }),
    });
  }

  async exportSkills(echoId: string): Promise<Record<string, unknown>> {
    return this.request(`/echoes/${echoId}/export_skills`);
  }

  async getChainStatus(echoId: string): Promise<ChainStatus> {
    return this.request(`/echoes/${echoId}/chain_status`);
  }

  // === Story Sessions ===
  async createStorySession(echoId: string, chapter: string = 'chapter_1'): Promise<StorySession> {
    return this.request('/story_sessions', {
      method: 'POST',
      body: JSON.stringify({ echo_id: echoId, chapter }),
    });
  }

  async getStorySession(sessionId: string): Promise<StorySession> {
    return this.request(`/story_sessions/${sessionId}`);
  }

  async submitChoice(sessionId: string, choiceIndex: number): Promise<ChoiceResponse> {
    return this.request(`/story_sessions/${sessionId}/choose`, {
      method: 'POST',
      body: JSON.stringify({ choice_index: choiceIndex }),
    });
  }

  async generateScene(sessionId: string): Promise<{ scene: StoryScene; session: StorySession }> {
    return this.request(`/story_sessions/${sessionId}/generate_scene`, {
      method: 'POST',
    });
  }

  async pauseStorySession(sessionId: string): Promise<{ message: string; session: StorySession }> {
    return this.request(`/story_sessions/${sessionId}/pause`, {
      method: 'POST',
    });
  }

  async resumeStorySession(sessionId: string): Promise<StorySession> {
    return this.request(`/story_sessions/${sessionId}/resume`, {
      method: 'POST',
    });
  }

  async getStoryLog(sessionId: string): Promise<StoryLogResponse> {
    return this.request(`/story_sessions/${sessionId}/story_log`);
  }

  // === Conversations (chat with Echo or Tiara) ===
  async getConversations(echoId: string, partner: ChatPartner = 'echo'): Promise<EchoConversation[]> {
    return this.request(`/conversations?echo_id=${echoId}&partner=${partner}`);
  }

  async createConversation(echoId: string, partner: ChatPartner = 'echo'): Promise<EchoConversation> {
    return this.request('/conversations', {
      method: 'POST',
      body: JSON.stringify({ echo_id: echoId, partner }),
    });
  }

  async getMessages(conversationId: string): Promise<EchoMessage[]> {
    return this.request(`/conversations/${conversationId}/messages`);
  }

  async sendMessage(conversationId: string, content: string): Promise<EchoMessage> {
    const response = await this.request<{ user_message: EchoMessage; assistant_message: EchoMessage }>(
      `/conversations/${conversationId}/messages`,
      {
        method: 'POST',
        body: JSON.stringify({ message: { content } }),
      }
    );
    return response.assistant_message;
  }
}

const apiClient = new ApiClient();

// Auth exports
export const login = (email: string, password: string) =>
  apiClient.login(email, password);
export const signup = (name: string, email: string, password: string, password_confirmation: string) =>
  apiClient.signup(name, email, password, password_confirmation);
export const googleAuth = (token: string) =>
  apiClient.googleAuth(token);
export const forgotPassword = (email: string) =>
  apiClient.forgotPassword(email);
export const resetPassword = (token: string, password: string, password_confirmation: string) =>
  apiClient.resetPassword(token, password, password_confirmation);

// Echo exports
export const getEchoes = () => apiClient.getEchoes();
export const getEcho = (id: string) => apiClient.getEcho(id);
export const createEcho = (name: string) => apiClient.createEcho(name);
export const exportSkills = (echoId: string) => apiClient.exportSkills(echoId);
export const getChainStatus = (echoId: string) => apiClient.getChainStatus(echoId);

// Story exports
export const createStorySession = (echoId: string, chapter?: string) =>
  apiClient.createStorySession(echoId, chapter);
export const getStorySession = (sessionId: string) =>
  apiClient.getStorySession(sessionId);
export const submitChoice = (sessionId: string, choiceIndex: number) =>
  apiClient.submitChoice(sessionId, choiceIndex);
export const generateScene = (sessionId: string) =>
  apiClient.generateScene(sessionId);
export const pauseStorySession = (sessionId: string) =>
  apiClient.pauseStorySession(sessionId);
export const resumeStorySession = (sessionId: string) =>
  apiClient.resumeStorySession(sessionId);
export const getStoryLog = (sessionId: string) =>
  apiClient.getStoryLog(sessionId);

// Chat exports
export const getConversations = (echoId: string, partner: ChatPartner = 'echo') =>
  apiClient.getConversations(echoId, partner);
export const createConversation = (echoId: string, partner: ChatPartner = 'echo') =>
  apiClient.createConversation(echoId, partner);
export const getMessages = (conversationId: string) =>
  apiClient.getMessages(conversationId);
export const sendMessage = (conversationId: string, content: string) =>
  apiClient.sendMessage(conversationId, content);

export default apiClient;
