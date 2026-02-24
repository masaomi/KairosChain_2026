'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';
import EchoCard from '@/components/echo/EchoCard';
import LoadingSpinner from '@/components/ui/LoadingSpinner';
import { getEchoes, createEcho } from '@/lib/api';
import { Echo } from '@/types';
import { Plus } from 'lucide-react';

function HomePageContent() {
  const [echoes, setEchoes] = useState<Echo[]>([]);
  const [loading, setLoading] = useState(true);
  const [creatingEcho, setCreatingEcho] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    fetchEchoes();
  }, []);

  const fetchEchoes = async () => {
    try {
      const data = await getEchoes();
      setEchoes(data);
    } catch (err: any) {
      setError('エコーの読み込みに失敗しました');
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const handleCreateEcho = async () => {
    setCreatingEcho(true);
    try {
      const newEcho = await createEcho('新しいエコー');
      setEchoes([...echoes, newEcho]);
    } catch (err: any) {
      setError('エコーの作成に失敗しました');
      console.error(err);
    } finally {
      setCreatingEcho(false);
    }
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] flex items-center justify-center">
        <LoadingSpinner />
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] relative">
      {/* Background decoration */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-20 right-20 w-72 h-72 bg-[#50c878]/5 rounded-full blur-3xl animate-pulse-slow" />
        <div className="absolute bottom-20 left-20 w-96 h-96 bg-[#d4af37]/5 rounded-full blur-3xl animate-pulse-slow" />
      </div>

      <Header />

      {/* Content */}
      <main className="relative z-10 max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8 sm:py-12">
        {/* Page Title */}
        <div className="mb-12 sm:mb-16">
          <h1 className="text-3xl sm:text-4xl font-serif font-bold text-[#d4af37] mb-3">
            あなたのエコー
          </h1>
          <p className="text-[#b0b0b0] text-base sm:text-lg">
            AIガイドを育成し、ティアラとともに物語を紡ぎます
          </p>
        </div>

        {/* Error Message */}
        {error && (
          <div className="mb-6 p-4 rounded-lg bg-red-900/20 border border-red-500/30">
            <p className="text-sm text-red-200">{error}</p>
          </div>
        )}

        {/* Echoes Grid */}
        {echoes.length > 0 ? (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 sm:gap-8 mb-12">
            {echoes.map((echo) => (
              <EchoCard key={echo.id} echo={echo} />
            ))}

            {/* Create New Echo Card */}
            <button
              onClick={handleCreateEcho}
              disabled={creatingEcho}
              className="group glass-morphism rounded-2xl p-8 min-h-80 flex flex-col items-center justify-center gap-4 hover:bg-white/10 transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <div className="w-16 h-16 rounded-full bg-gradient-to-br from-[#d4af37] to-[#50c878] flex items-center justify-center group-hover:scale-110 transition-transform">
                <Plus className="w-8 h-8 text-[#1a0a2e]" />
              </div>
              <p className="text-[#d4af37] font-semibold text-lg text-center">
                {creatingEcho ? '作成中...' : '新しいエコーを作成'}
              </p>
              <p className="text-[#b0b0b0] text-sm text-center">
                新しいAI人格を育成を始める
              </p>
            </button>
          </div>
        ) : (
          /* Empty State */
          <div className="glass-morphism rounded-2xl p-8 sm:p-12 text-center mb-12">
            <div className="mb-6">
              <div className="w-20 h-20 mx-auto rounded-full bg-gradient-to-br from-[#d4af37] to-[#50c878] flex items-center justify-center mb-6">
                <span className="text-3xl">✨</span>
              </div>
            </div>

            <h2 className="text-2xl sm:text-3xl font-serif font-bold text-[#d4af37] mb-4">
              エコーはまだいません
            </h2>

            <p className="text-[#b0b0b0] text-base sm:text-lg mb-8 max-w-md mx-auto">
              あなたのAI人格「エコー」を作成して、ティアラとともに冒険の物語を始めましょう。
            </p>

            <button
              onClick={handleCreateEcho}
              disabled={creatingEcho}
              className="button-primary inline-block px-8 py-4 text-lg disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {creatingEcho ? '作成中...' : 'エコーを作成'}
            </button>
          </div>
        )}

        {/* Quick Links */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Link
            href="/settings"
            className="glass-morphism rounded-lg p-4 text-center hover:bg-white/10 transition-colors text-[#d4af37] font-semibold"
          >
            設定
          </Link>
          <button
            onClick={() => {
              localStorage.removeItem('token');
              window.location.href = '/';
            }}
            className="glass-morphism rounded-lg p-4 text-center hover:bg-white/10 transition-colors text-[#d4af37] font-semibold cursor-pointer"
          >
            ログアウト
          </button>
        </div>
      </main>
    </div>
  );
}

export default function HomePage() {
  return (
    <AuthGuard>
      <HomePageContent />
    </AuthGuard>
  );
}
