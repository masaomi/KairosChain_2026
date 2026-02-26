'use client';

import { useState, useEffect, useRef, Suspense } from 'react';
import { useParams, useRouter, useSearchParams } from 'next/navigation';
import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';
import ChatMessage from '@/components/chat/ChatMessage';
import ChatInput from '@/components/chat/ChatInput';
import EchoAvatar from '@/components/echo/EchoAvatar';
import LoadingSpinner from '@/components/ui/LoadingSpinner';
import { getEcho, getConversations, createConversation, getMessages, sendMessage } from '@/lib/api';
import { Echo, EchoMessage, ChatPartner } from '@/types';
import { ArrowLeft } from 'lucide-react';
import Link from 'next/link';

function ChatPageInner() {
  const { id } = useParams() as { id: string };
  const router = useRouter();
  const searchParams = useSearchParams();
  const partner = (searchParams.get('partner') as ChatPartner) || 'echo';

  const [echo, setEcho] = useState<Echo | null>(null);
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [messages, setMessages] = useState<EchoMessage[]>([]);
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState('');
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const isTiara = partner === 'tiara';

  useEffect(() => {
    initializeChat();
  }, [id, partner]);

  useEffect(() => {
    scrollToBottom();
  }, [messages]);

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  const initializeChat = async () => {
    setLoading(true);
    setMessages([]);
    setConversationId(null);
    setError('');

    try {
      const echoData = await getEcho(id);
      setEcho(echoData);

      // For Tiara chat, check chapter 1 completion
      if (isTiara && !echoData.chapter_1_completed) {
        router.push(`/echo/${id}`);
        return;
      }

      // Get or create conversation for this partner
      const conversations = await getConversations(id, partner);
      let convId: string;
      if (conversations.length > 0) {
        convId = conversations[0].id;
        const msgs = await getMessages(convId);
        setMessages(msgs);
      } else {
        const newConv = await createConversation(id, partner);
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
      setMessages((prev) => [...prev, response]);
    } catch (err: any) {
      setError('メッセージの送信に失敗しました');
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

  // Theme colors based on partner
  const themeColor = isTiara ? '#c0a0d0' : '#d4af37';
  const themeGradient = isTiara
    ? 'from-[#9b59b6] to-[#c0a0d0]'
    : 'from-[#d4af37] to-[#50c878]';
  const loadingDotColor = isTiara ? 'bg-[#c0a0d0]' : 'bg-[#50c878]';
  const partnerName = isTiara ? 'ティアラ' : echo.name;
  const partnerEmoji = isTiara ? '🐱' : '💎';

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
              className="hover:opacity-80 transition-opacity"
              style={{ color: themeColor }}
            >
              <ArrowLeft className="w-5 h-5" />
            </Link>
            {isTiara ? (
              <div className={`w-10 h-10 rounded-full bg-gradient-to-br ${themeGradient} flex items-center justify-center text-lg`}>
                🐱
              </div>
            ) : (
              <EchoAvatar status={echo.status} size="sm" />
            )}
            <div>
              <h1 className="text-xl sm:text-2xl font-serif font-bold" style={{ color: themeColor }}>
                {partnerName}
              </h1>
              <p className="text-xs sm:text-sm text-[#b0b0b0]">
                {isTiara ? '紫の導き手' : 'オンライン'}
              </p>
            </div>
          </div>

          {/* Partner switch tabs */}
          <div className="flex gap-2">
            <Link
              href={`/echo/${id}/chat?partner=echo`}
              className={`px-3 py-1.5 rounded-full text-xs font-semibold transition-colors ${
                !isTiara
                  ? 'bg-[#d4af37]/20 text-[#d4af37] border border-[#d4af37]/30'
                  : 'text-[#b0b0b0] hover:text-[#d4af37]'
              }`}
            >
              {echo.name}
            </Link>
            {echo.chapter_1_completed && (
              <Link
                href={`/echo/${id}/chat?partner=tiara`}
                className={`px-3 py-1.5 rounded-full text-xs font-semibold transition-colors ${
                  isTiara
                    ? 'bg-[#9b59b6]/20 text-[#c0a0d0] border border-[#9b59b6]/30'
                    : 'text-[#b0b0b0] hover:text-[#c0a0d0]'
                }`}
              >
                ティアラ
              </Link>
            )}
          </div>
        </div>
      </div>

      {/* Messages Container */}
      <div className="relative z-10 flex-1 overflow-y-auto max-w-4xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-6 sm:py-8">
        {messages.length === 0 && (
          <div className="h-full flex items-center justify-center text-center">
            <div>
              <div className="text-5xl mb-4">{isTiara ? '🐱' : '💬'}</div>
              <h2 className="text-2xl font-serif font-bold mb-2" style={{ color: themeColor }}>
                {isTiara ? 'ティアラと話そう' : '会話を始めましょう'}
              </h2>
              <p className="text-[#b0b0b0]">
                {isTiara
                  ? '紫の導き手に話しかけてみてください'
                  : `${echo.name}に何か話しかけてみてください`}
              </p>
            </div>
          </div>
        )}

        <div className="space-y-4">
          {messages.map((message) => (
            <ChatMessage key={message.id} message={message} echo={echo} partner={partner} />
          ))}
          {sending && (
            <div className="flex justify-start">
              <div className="flex items-end gap-3">
                <div className={`flex-shrink-0 w-8 h-8 rounded-full bg-gradient-to-br ${themeGradient} flex items-center justify-center text-sm`}>
                  {partnerEmoji}
                </div>
                <div className="glass-morphism rounded-lg p-4 max-w-xs">
                  <div className="flex gap-2 items-center">
                    <div className={`w-2 h-2 ${loadingDotColor} rounded-full animate-bounce`} />
                    <div className={`w-2 h-2 ${loadingDotColor} rounded-full animate-bounce`} style={{ animationDelay: '0.1s' }} />
                    <div className={`w-2 h-2 ${loadingDotColor} rounded-full animate-bounce`} style={{ animationDelay: '0.2s' }} />
                  </div>
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
            placeholder={isTiara ? 'ティアラに話しかける... (Enterで送信)' : undefined}
          />
        </div>
      </div>
    </div>
  );
}

function ChatPageContent() {
  return (
    <Suspense fallback={
      <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] flex items-center justify-center">
        <LoadingSpinner />
      </div>
    }>
      <ChatPageInner />
    </Suspense>
  );
}

export default function ChatPage() {
  return (
    <AuthGuard>
      <ChatPageContent />
    </AuthGuard>
  );
}
