'use client';

import { useState, useEffect, useRef } from 'react';
import { useParams, useRouter } from 'next/navigation';
import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';
import ChatMessage from '@/components/chat/ChatMessage';
import ChatInput from '@/components/chat/ChatInput';
import EchoAvatar from '@/components/echo/EchoAvatar';
import LoadingSpinner from '@/components/ui/LoadingSpinner';
import { getEcho, getConversations, createConversation, getMessages, sendMessage } from '@/lib/api';
import { Echo, EchoMessage } from '@/types';
import { ArrowLeft } from 'lucide-react';
import Link from 'next/link';

function ChatPageContent() {
  const { id } = useParams() as { id: string };
  const router = useRouter();
  const [echo, setEcho] = useState<Echo | null>(null);
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [messages, setMessages] = useState<EchoMessage[]>([]);
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState('');
  const messagesEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    initializeChat();
  }, [id]);

  useEffect(() => {
    scrollToBottom();
  }, [messages]);

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  const initializeChat = async () => {
    try {
      const echoData = await getEcho(id);

      // Redirect if not crystallized
      if (echoData.status !== 'crystallized') {
        router.push(`/echo/${id}`);
        return;
      }

      setEcho(echoData);

      // Get or create conversation
      const conversations = await getConversations(id);
      let convId: string;
      if (conversations.length > 0) {
        convId = conversations[0].id;
        const msgs = await getMessages(convId);
        setMessages(msgs);
      } else {
        const newConv = await createConversation(id);
        convId = newConv.id;
      }
      setConversationId(convId);
    } catch (err: any) {
      setError('チャットの読み込みに失敗しました');
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const handleSendMessage = async (content: string) => {
    if (!content.trim()) return;

    // Add user message immediately
    if (!conversationId) return;

    const userMessage: EchoMessage = {
      id: `temp-${Date.now()}`,
      role: 'user',
      content,
      created_at: new Date().toISOString(),
    };

    setMessages((prev) => [...prev, userMessage]);
    setSending(true);
    setError('');

    try {
      const response = await sendMessage(conversationId, content);

      // Add Echo's response
      setMessages((prev) => [...prev, response]);
    } catch (err: any) {
      setError('メッセージの送信に失敗しました');
      // Remove user message on error
      setMessages((prev) => prev.filter((msg) => msg.id !== userMessage.id));
      console.error(err);
    } finally {
      setSending(false);
    }
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] flex items-center justify-center">
        <LoadingSpinner />
      </div>
    );
  }

  if (!echo) {
    return (
      <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460]">
        <Header />
        <main className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
          <Link
            href="/home"
            className="inline-flex items-center gap-2 text-[#d4af37] hover:text-[#e8c547] mb-8"
          >
            <ArrowLeft className="w-4 h-4" />
            戻る
          </Link>
          <div className="glass-morphism rounded-2xl p-8 text-center">
            <p className="text-[#b0b0b0] mb-6">エコーが見つかりません</p>
            <Link href="/home" className="button-primary px-6 py-3">
              ホームに戻る
            </Link>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] flex flex-col relative">
      {/* Background decoration */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-20 right-20 w-72 h-72 bg-[#50c878]/5 rounded-full blur-3xl animate-pulse-slow" />
        <div className="absolute bottom-20 left-20 w-96 h-96 bg-[#d4af37]/5 rounded-full blur-3xl animate-pulse-slow" />
      </div>

      <Header />

      {/* Chat Header */}
      <div className="relative z-10 border-b border-white/10 bg-black/20 backdrop-blur-md">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-4 sm:py-6 flex items-center justify-between">
          <div className="flex items-center gap-4">
            <Link
              href={`/echo/${id}`}
              className="text-[#d4af37] hover:text-[#e8c547] transition-colors"
            >
              <ArrowLeft className="w-5 h-5" />
            </Link>
            <EchoAvatar status={echo.status} size="sm" />
            <div>
              <h1 className="text-xl sm:text-2xl font-serif font-bold text-[#d4af37]">
                {echo.name}
              </h1>
              <p className="text-xs sm:text-sm text-[#b0b0b0]">
                オンライン
              </p>
            </div>
          </div>
        </div>
      </div>

      {/* Messages Container */}
      <div className="relative z-10 flex-1 overflow-y-auto max-w-4xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-6 sm:py-8">
        {messages.length === 0 && (
          <div className="h-full flex items-center justify-center text-center">
            <div>
              <div className="text-5xl mb-4">💬</div>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-2">
                会話を始めましょう
              </h2>
              <p className="text-[#b0b0b0]">
                {echo.name}に何か話しかけてみてください
              </p>
            </div>
          </div>
        )}

        <div className="space-y-4">
          {messages.map((message) => (
            <ChatMessage key={message.id} message={message} echo={echo} />
          ))}
          {sending && (
            <div className="flex justify-start">
              <div className="glass-morphism rounded-lg p-4 max-w-xs">
                <div className="flex gap-2 items-center">
                  <div className="w-2 h-2 bg-[#50c878] rounded-full animate-bounce" />
                  <div className="w-2 h-2 bg-[#50c878] rounded-full animate-bounce" style={{ animationDelay: '0.1s' }} />
                  <div className="w-2 h-2 bg-[#50c878] rounded-full animate-bounce" style={{ animationDelay: '0.2s' }} />
                </div>
              </div>
            </div>
          )}
          <div ref={messagesEndRef} />
        </div>
      </div>

      {/* Error Message */}
      {error && (
        <div className="relative z-10 max-w-4xl w-full mx-auto px-4 sm:px-6 lg:px-8 mb-4">
          <div className="p-4 rounded-lg bg-red-900/20 border border-red-500/30">
            <p className="text-sm text-red-200">{error}</p>
          </div>
        </div>
      )}

      {/* Input Area */}
      <div className="relative z-10 border-t border-white/10 bg-black/20 backdrop-blur-md">
        <div className="max-w-4xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-4 sm:py-6">
          <ChatInput
            onSendMessage={handleSendMessage}
            disabled={sending}
          />
        </div>
      </div>
    </div>
  );
}

export default function ChatPage() {
  return (
    <AuthGuard>
      <ChatPageContent />
    </AuthGuard>
  );
}
