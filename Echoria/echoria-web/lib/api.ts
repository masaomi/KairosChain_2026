import { getToken, removeToken } from './auth';
import {
  User,
  Echo,
  StoryScene,
  EchoConversation,
  EchoMessage,
  ApiResponse,
} from '@/types';

const API_BASE_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:3000/api';

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
        errorMessage = errorData.message || errorMessage;
      } catch {
        // ignore
      }
      throw new Error(errorMessage);
    }

    return response.json();
  }

  // Auth endpoints
  async login(email: string, password: string): Promise<{ token: string; user: User }> {
    return this.request('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    });
  }

  async signup(
    name: string,
    email: string,
    password: string
  ): Promise<{ token: string; user: User }> {
    return this.request('/auth/signup', {
      method: 'POST',
      body: JSON.stringify({ name, email, password }),
    });
  }

  async googleAuth(token: string): Promise<{ token: string; user: User }> {
    return this.request('/auth/google', {
      method: 'POST',
      body: JSON.stringify({ token }),
    });
  }

  // Echo endpoints
  async getEchoes(): Promise<Echo[]> {
    return this.request('/echoes');
  }

  async getEcho(id: string): Promise<Echo> {
    return this.request(`/echoes/${id}`);
  }

  async createEcho(name: string): Promise<Echo> {
    return this.request('/echoes', {
      method: 'POST',
      body: JSON.stringify({ name }),
    });
  }

  // Story endpoints
  async startStory(echoId: string): Promise<StoryScene> {
    return this.request(`/echoes/${echoId}/story/start`, {
      method: 'POST',
    });
  }

  async submitChoice(
    echoId: string,
    sceneId: string,
    choiceId: string
  ): Promise<StoryScene> {
    return this.request(`/echoes/${echoId}/story/choice`, {
      method: 'POST',
      body: JSON.stringify({ sceneId, choiceId }),
    });
  }

  async generateScene(echoId: string, mode: string): Promise<StoryScene> {
    return this.request(`/echoes/${echoId}/story/generate`, {
      method: 'POST',
      body: JSON.stringify({ mode }),
    });
  }

  // Chat endpoints
  async getConversations(echoId: string): Promise<EchoConversation> {
    return this.request(`/echoes/${echoId}/conversations`);
  }

  async sendMessage(echoId: string, content: string): Promise<EchoMessage> {
    return this.request(`/echoes/${echoId}/messages`, {
      method: 'POST',
      body: JSON.stringify({ content }),
    });
  }
}

const apiClient = new ApiClient();

export const login = (email: string, password: string) =>
  apiClient.login(email, password);

export const signup = (name: string, email: string, password: string) =>
  apiClient.signup(name, email, password);

export const googleAuth = (token: string) =>
  apiClient.googleAuth(token);

export const getEchoes = () =>
  apiClient.getEchoes();

export const getEcho = (id: string) =>
  apiClient.getEcho(id);

export const createEcho = (name: string) =>
  apiClient.createEcho(name);

export const startStory = (echoId: string) =>
  apiClient.startStory(echoId);

export const submitChoice = (echoId: string, sceneId: string, choiceId: string) =>
  apiClient.submitChoice(echoId, sceneId, choiceId);

export const generateScene = (echoId: string, mode: string) =>
  apiClient.generateScene(echoId, mode);

export const getConversations = (echoId: string) =>
  apiClient.getConversations(echoId);

export const sendMessage = (echoId: string, content: string) =>
  apiClient.sendMessage(echoId, content);

export default apiClient;
