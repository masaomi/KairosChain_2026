'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';
import PersonalityRadar from '@/components/echo/PersonalityRadar';
import EchoAvatar from '@/components/echo/EchoAvatar';
import LoadingSpinner from '@/components/ui/LoadingSpinner';
import { getEcho } from '@/lib/api';
import { Echo } from '@/types';
import { ArrowLeft, MessageCircle, BookOpen } from 'lucide-react';

function EchoProfileContent() {
  const { id } = useParams() as { id: string };
  const [echo, setEcho] = useState<Echo | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    fetchEcho();
  }, [id]);

  const fetchEcho = async () => {
    try {
      const data = await getEcho(id);
      setEcho(data);
    } catch (err: any) {
      setError('エコーの読み込みに失敗しました');
      console.error(err);
    } finally {
      setLoading(false);
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
            <p className="text-[#b0b0b0]">エコーが見つかりません</p>
          </div>
        </main>
      </div>
    );
  }

  const statusLabels: Record<string, string> = {
    embryo: '胚胎',
    growing: '成長中',
    crystallized: '結晶化',
  };

  const statusColor: Record<string, string> = {
    embryo: 'bg-yellow-500/20 text-yellow-200 border-yellow-500/30',
    growing: 'bg-blue-500/20 text-blue-200 border-blue-500/30',
    crystallized: 'bg-purple-500/20 text-purple-200 border-purple-500/30',
  };

  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] relative">
      {/* Background decoration */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-20 right-20 w-72 h-72 bg-[#50c878]/5 rounded-full blur-3xl animate-pulse-slow" />
        <div className="absolute bottom-20 left-20 w-96 h-96 bg-[#d4af37]/5 rounded-full blur-3xl animate-pulse-slow" />
      </div>

      <Header />

      <main className="relative z-10 max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8 sm:py-12">
        {/* Back Button */}
        <Link
          href="/home"
          className="inline-flex items-center gap-2 text-[#d4af37] hover:text-[#e8c547] mb-8 transition-colors"
        >
          <ArrowLeft className="w-4 h-4" />
          <span className="text-sm sm:text-base">戻る</span>
        </Link>

        {/* Error Message */}
        {error && (
          <div className="mb-6 p-4 rounded-lg bg-red-900/20 border border-red-500/30">
            <p className="text-sm text-red-200">{error}</p>
          </div>
        )}

        {/* Profile Header */}
        <div className="glass-morphism rounded-2xl p-6 sm:p-8 mb-8">
          <div className="flex flex-col sm:flex-row gap-6 sm:gap-8">
            {/* Avatar */}
            <div className="flex-shrink-0">
              <EchoAvatar status={echo.status} size="lg" />
            </div>

            {/* Info */}
            <div className="flex-1">
              <div className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4 mb-6">
                <div>
                  <h1 className="text-3xl sm:text-4xl font-serif font-bold text-[#d4af37] mb-2">
                    {echo.name}
                  </h1>
                  <div className="flex items-center gap-3">
                    <span className={`text-xs sm:text-sm font-semibold px-3 py-1 rounded-full border ${statusColor[echo.status]}`}>
                      {statusLabels[echo.status]}
                    </span>
                  </div>
                </div>

                {/* Action Buttons */}
                <div className="flex flex-col gap-3 sm:w-auto">
                  {echo.status === 'crystallized' && (
                    <Link
                      href={`/echo/${id}/chat`}
                      className="button-primary inline-flex items-center justify-center gap-2 px-6 py-3 text-sm sm:text-base"
                    >
                      <MessageCircle className="w-4 h-4" />
                      チャット
                    </Link>
                  )}
                  <Link
                    href={`/echo/${id}/story`}
                    className="button-secondary inline-flex items-center justify-center gap-2 px-6 py-3 text-sm sm:text-base"
                  >
                    <BookOpen className="w-4 h-4" />
                    物語を続ける
                  </Link>
                </div>
              </div>

              {/* Stats */}
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
                <div>
                  <p className="text-xs text-[#b0b0b0] mb-1">進捗</p>
                  <p className="text-xl sm:text-2xl font-semibold text-[#50c878]">
                    {echo.storyProgress || 0}%
                  </p>
                </div>
                <div>
                  <p className="text-xs text-[#b0b0b0] mb-1">キーモーメント</p>
                  <p className="text-xl sm:text-2xl font-semibold text-[#d4af37]">
                    {echo.keyMoments?.length || 0}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-[#b0b0b0] mb-1">ティアラの絆</p>
                  <p className="text-xl sm:text-2xl font-semibold text-[#50c878]">
                    {Math.round((echo.affinity?.tiaraAffinity || 0) * 100)}%
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Personality Radar */}
        <div className="glass-morphism rounded-2xl p-6 sm:p-8 mb-8">
          <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-8">
            人格の軌跡
          </h2>
          <div className="flex justify-center">
            <PersonalityRadar affinity={echo.affinity} />
          </div>
        </div>

        {/* Key Moments */}
        {echo.keyMoments && echo.keyMoments.length > 0 && (
          <div className="glass-morphism rounded-2xl p-6 sm:p-8">
            <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-6">
              重要な瞬間
            </h2>
            <div className="space-y-4">
              {echo.keyMoments.map((moment, idx) => (
                <div
                  key={idx}
                  className="border-l-2 border-[#d4af37] pl-4 py-2"
                >
                  <p className="text-sm text-[#b0b0b0] mb-1">
                    {new Date(moment.timestamp).toLocaleString('ja-JP')}
                  </p>
                  <p className="text-[#f5f5f5]">{moment.description}</p>
                </div>
              ))}
            </div>
          </div>
        )}
      </main>
    </div>
  );
}

export default function EchoProfilePage() {
  return (
    <AuthGuard>
      <EchoProfileContent />
    </AuthGuard>
  );
}
