'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';
import PersonalityRadar from '@/components/echo/PersonalityRadar';
import EchoAvatar from '@/components/echo/EchoAvatar';
import LoadingSpinner from '@/components/ui/LoadingSpinner';
import { getEcho, exportSkills, getChainStatus } from '@/lib/api';
import { Echo, ChainStatus } from '@/types';
import { ArrowLeft, MessageCircle, BookOpen, Lock, Cat, ScrollText, Play, Pause, Download, Link2 } from 'lucide-react';

function EchoProfileContent() {
  const { id } = useParams() as { id: string };
  const [echo, setEcho] = useState<Echo | null>(null);
  const [loading, setLoading] = useState(true);
  const [exporting, setExporting] = useState(false);
  const [chainStatus, setChainStatus] = useState<ChainStatus | null>(null);
  const [error, setError] = useState('');

  useEffect(() => {
    fetchEcho();
  }, [id]);

  const fetchEcho = async () => {
    try {
      const data = await getEcho(id);
      setEcho(data);
      // Fetch chain status in background
      getChainStatus(id).then(setChainStatus).catch(() => {});
    } catch (err: any) {
      setError('エコーの読み込みに失敗しました');
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const handleExportSkills = async () => {
    if (!echo || exporting) return;
    setExporting(true);
    try {
      const data = await exportSkills(echo.id);
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${echo.name}_skillset.json`;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    } catch (err) {
      console.error('Export failed:', err);
      setError('スキルのエクスポートに失敗しました');
    } finally {
      setExporting(false);
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

  const chapter1Done = echo.chapter_1_completed ?? false;

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
              </div>

              {/* Stats */}
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
                <div>
                  <p className="text-xs text-[#b0b0b0] mb-1">ティアラの絆</p>
                  <p className="text-xl sm:text-2xl font-semibold text-[#50c878]">
                    {echo.personality?.affinities?.tiara_trust ?? 50}%
                  </p>
                </div>
                <div>
                  <p className="text-xs text-[#b0b0b0] mb-1">カケラ</p>
                  <p className="text-xl sm:text-2xl font-semibold text-[#d4af37]">
                    {echo.personality?.affinities?.fragment_count ?? 0}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-[#b0b0b0] mb-1">原型</p>
                  <p className="text-lg sm:text-xl font-semibold text-[#f5f5f5] truncate">
                    {echo.personality?.primary_archetype
                      ? echo.personality.primary_archetype.split('（')[0]
                      : '—'}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Action Cards */}
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 sm:gap-6 mb-8">
          {/* Story Button — shows status */}
          {(() => {
            const sessions = echo.story_sessions || [];
            const activeSession = sessions.find(s => s.status === 'active');
            const pausedSession = sessions.find(s => s.status === 'paused');
            const completedSession = sessions.find(s => s.status === 'completed');
            const currentSession = activeSession || pausedSession;
            const isPaused = !!pausedSession && !activeSession;

            return (
              <Link
                href={`/echo/${id}/story`}
                className="glass-morphism rounded-2xl p-6 hover:bg-white/10 transition-all duration-200 group"
              >
                <div className="flex items-center gap-4 mb-3">
                  <div className="w-12 h-12 rounded-full bg-gradient-to-br from-[#d4af37] to-[#50c878] flex items-center justify-center group-hover:scale-110 transition-transform relative">
                    {isPaused ? (
                      <Play className="w-6 h-6 text-[#1a0a2e]" />
                    ) : (
                      <BookOpen className="w-6 h-6 text-[#1a0a2e]" />
                    )}
                    {isPaused && (
                      <div className="absolute -top-1 -right-1 w-4 h-4 rounded-full bg-yellow-500 flex items-center justify-center">
                        <Pause className="w-2.5 h-2.5 text-[#1a0a2e]" />
                      </div>
                    )}
                  </div>
                  <h3 className="text-lg font-serif font-bold text-[#d4af37]">
                    {isPaused ? '続きから再開' : completedSession ? '物語を読む' : '物語を始める'}
                  </h3>
                </div>
                <p className="text-sm text-[#b0b0b0]">
                  {isPaused
                    ? 'セーブデータがあります — タップで再開'
                    : completedSession
                      ? '第一章の冒険を振り返る'
                      : 'ティアラとともに残響界の冒険を進める'}
                </p>
              </Link>
            );
          })()}

          {/* Story Log Button */}
          {(() => {
            const sessions = echo.story_sessions || [];
            const anySession = sessions.find(s => s.status === 'active' || s.status === 'paused' || s.status === 'completed');
            if (!anySession) return null;

            return (
              <Link
                href={`/echo/${id}/story-log?session=${anySession.id}`}
                className="glass-morphism rounded-2xl p-6 hover:bg-white/10 transition-all duration-200 group"
              >
                <div className="flex items-center gap-4 mb-3">
                  <div className="w-12 h-12 rounded-full bg-gradient-to-br from-[#8b7355] to-[#d4af37] flex items-center justify-center group-hover:scale-110 transition-transform">
                    <ScrollText className="w-6 h-6 text-[#1a0a2e]" />
                  </div>
                  <h3 className="text-lg font-serif font-bold text-[#d4af37]">物語ログ</h3>
                </div>
                <p className="text-sm text-[#b0b0b0]">
                  これまでの冒険を小説として読む
                </p>
              </Link>
            );
          })()}

          {/* Echo Chat Button */}
          <Link
            href={`/echo/${id}/chat?partner=echo`}
            className="glass-morphism rounded-2xl p-6 hover:bg-white/10 transition-all duration-200 group"
          >
            <div className="flex items-center gap-4 mb-3">
              <div className="w-12 h-12 rounded-full bg-gradient-to-br from-[#d4af37] to-[#f0e68c] flex items-center justify-center group-hover:scale-110 transition-transform">
                <MessageCircle className="w-6 h-6 text-[#1a0a2e]" />
              </div>
              <h3 className="text-lg font-serif font-bold text-[#d4af37]">
                {echo.name}と会話
              </h3>
            </div>
            <p className="text-sm text-[#b0b0b0]">
              あなたのエコーと自由に対話する
            </p>
          </Link>

          {/* Tiara Chat Button */}
          {chapter1Done ? (
            <Link
              href={`/echo/${id}/chat?partner=tiara`}
              className="glass-morphism rounded-2xl p-6 hover:bg-white/10 transition-all duration-200 group border border-purple-500/20"
            >
              <div className="flex items-center gap-4 mb-3">
                <div className="w-12 h-12 rounded-full bg-gradient-to-br from-[#9b59b6] to-[#c0a0d0] flex items-center justify-center group-hover:scale-110 transition-transform">
                  <Cat className="w-6 h-6 text-white" />
                </div>
                <h3 className="text-lg font-serif font-bold text-[#c0a0d0]">
                  ティアラと会話
                </h3>
              </div>
              <p className="text-sm text-[#b0b0b0]">
                紫の導き手と物語の外で語り合う
              </p>
            </Link>
          ) : (
            <div className="glass-morphism rounded-2xl p-6 opacity-60 cursor-not-allowed relative overflow-hidden border border-purple-500/10">
              <div className="flex items-center gap-4 mb-3">
                <div className="w-12 h-12 rounded-full bg-gradient-to-br from-[#9b59b6]/40 to-[#c0a0d0]/40 flex items-center justify-center relative">
                  <Cat className="w-6 h-6 text-white/50" />
                  <div className="absolute -bottom-0.5 -right-0.5 w-5 h-5 rounded-full bg-[#1a0a2e] flex items-center justify-center">
                    <Lock className="w-3 h-3 text-[#b0b0b0]" />
                  </div>
                </div>
                <h3 className="text-lg font-serif font-bold text-[#c0a0d0]/50">
                  ティアラと会話
                </h3>
              </div>
              <p className="text-sm text-[#b0b0b0]/60">
                第一章を完了すると解放されます
              </p>
              {/* Decorative lock overlay */}
              <div className="absolute top-3 right-3">
                <Lock className="w-4 h-4 text-[#b0b0b0]/30" />
              </div>
            </div>
          )}
        </div>

        {/* Personality Radar */}
        <div className="glass-morphism rounded-2xl p-6 sm:p-8 mb-8">
          <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-8">
            人格の軌跡
          </h2>
          <div className="flex justify-center">
            <PersonalityRadar affinity={echo.personality?.affinities} />
          </div>
        </div>

        {/* KairosChain Status */}
        {chainStatus && chainStatus.available && chainStatus.blocks > 0 && (
          <div className="glass-morphism rounded-2xl p-6 sm:p-8 mb-8">
            <div className="flex items-center gap-3 mb-4">
              <Link2 className="w-5 h-5 text-[#50c878]" />
              <h2 className="text-lg font-serif font-bold text-[#50c878]">
                KairosChain
              </h2>
              {chainStatus.integrity && (
                <span className="text-[10px] px-2 py-0.5 rounded-full bg-[#50c878]/20 text-[#50c878] border border-[#50c878]/30">
                  verified
                </span>
              )}
            </div>
            <div className="flex items-center gap-6 mb-4 text-sm">
              <div>
                <span className="text-[#b0b0b0]">ブロック数: </span>
                <span className="text-[#f5f5f5] font-semibold">{chainStatus.blocks}</span>
              </div>
            </div>
            {chainStatus.recent_actions.length > 0 && (
              <div className="space-y-1.5">
                <p className="text-xs text-[#808080] mb-2">最近の記録</p>
                {chainStatus.recent_actions.slice(0, 5).map((action, idx) => (
                  <div key={idx} className="flex items-center gap-2 text-xs">
                    <div className="w-1 h-1 rounded-full bg-[#50c878]/60" />
                    <span className="text-[#b0b0b0]">
                      {action.action.replace(/_/g, ' ')}
                    </span>
                    <span className="text-[#606060] ml-auto">
                      {new Date(action.timestamp).toLocaleDateString('ja-JP', { month: 'short', day: 'numeric' })}
                    </span>
                  </div>
                ))}
              </div>
            )}
          </div>
        )}

        {/* Character Description (post-crystallization) */}
        {echo.personality?.character_description && (
          <div className="glass-morphism rounded-2xl p-6 sm:p-8">
            <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-6">
              人格の結晶
            </h2>
            <p className="text-[#f5f5f5] leading-relaxed whitespace-pre-wrap">
              {echo.personality.character_description}
            </p>
            {echo.personality.secondary_traits && echo.personality.secondary_traits.length > 0 && (
              <div className="mt-4 flex flex-wrap gap-2">
                {echo.personality.secondary_traits.map((trait, idx) => (
                  <span
                    key={idx}
                    className="text-xs px-3 py-1 rounded-full bg-[#d4af37]/20 text-[#d4af37] border border-[#d4af37]/30"
                  >
                    {trait}
                  </span>
                ))}
              </div>
            )}
          </div>
        )}

        {/* Skill Export (post-crystallization) */}
        {echo.status === 'crystallized' && (
          <div className="glass-morphism rounded-2xl p-6 sm:p-8 mt-8 border border-[#50c878]/20">
            <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
              <div>
                <h2 className="text-xl font-serif font-bold text-[#50c878] mb-2">
                  SkillSetをダウンロード
                </h2>
                <p className="text-sm text-[#b0b0b0]">
                  あなたのエコーをKairosChain MCP serverに持ち帰る
                </p>
              </div>
              <button
                onClick={handleExportSkills}
                disabled={exporting}
                className="flex items-center gap-2 px-6 py-3 rounded-lg bg-[#50c878]/20 text-[#50c878] border border-[#50c878]/40 hover:bg-[#50c878]/30 transition-colors font-semibold text-sm disabled:opacity-50"
              >
                <Download className="w-4 h-4" />
                {exporting ? 'エクスポート中...' : 'JSON ダウンロード'}
              </button>
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
