'use client';

import { useState } from 'react';
import Link from 'next/link';
import Header from '@/components/layout/Header';
import AuthGuard from '@/components/layout/AuthGuard';
import { removeToken } from '@/lib/auth';
import { ArrowLeft } from 'lucide-react';

function SettingsPageContent() {
  const [notifications, setNotifications] = useState(true);
  const [theme, setTheme] = useState('dark');
  const [language, setLanguage] = useState('ja');

  const handleLogout = () => {
    removeToken();
    window.location.href = '/';
  };

  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] relative">
      {/* Background decoration */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-20 right-20 w-72 h-72 bg-[#50c878]/5 rounded-full blur-3xl animate-pulse-slow" />
        <div className="absolute bottom-20 left-20 w-96 h-96 bg-[#d4af37]/5 rounded-full blur-3xl animate-pulse-slow" />
      </div>

      <Header />

      <main className="relative z-10 max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-8 sm:py-12">
        {/* Back Button */}
        <Link
          href="/home"
          className="inline-flex items-center gap-2 text-[#d4af37] hover:text-[#e8c547] mb-8 transition-colors"
        >
          <ArrowLeft className="w-4 h-4" />
          戻る
        </Link>

        {/* Page Title */}
        <h1 className="text-3xl sm:text-4xl font-serif font-bold text-[#d4af37] mb-8">
          設定
        </h1>

        {/* Settings Sections */}
        <div className="space-y-6">
          {/* Display Settings */}
          <div className="glass-morphism rounded-2xl p-6 sm:p-8">
            <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-6">
              表示設定
            </h2>

            <div className="space-y-6">
              {/* Theme */}
              <div className="flex items-center justify-between pb-6 border-b border-white/10">
                <div>
                  <p className="text-[#f5f5f5] font-semibold mb-1">テーマ</p>
                  <p className="text-sm text-[#b0b0b0]">
                    アプリの外観を選択
                  </p>
                </div>
                <select
                  value={theme}
                  onChange={(e) => setTheme(e.target.value)}
                  className="px-4 py-2 rounded-lg bg-white/5 border border-white/10 text-[#f5f5f5] focus:outline-none focus:border-[#d4af37]/50"
                >
                  <option value="dark">ダーク (デフォルト)</option>
                  <option value="light">ライト</option>
                </select>
              </div>

              {/* Language */}
              <div className="flex items-center justify-between pb-6 border-b border-white/10">
                <div>
                  <p className="text-[#f5f5f5] font-semibold mb-1">言語</p>
                  <p className="text-sm text-[#b0b0b0]">
                    表示言語を選択
                  </p>
                </div>
                <select
                  value={language}
                  onChange={(e) => setLanguage(e.target.value)}
                  className="px-4 py-2 rounded-lg bg-white/5 border border-white/10 text-[#f5f5f5] focus:outline-none focus:border-[#d4af37]/50"
                >
                  <option value="ja">日本語</option>
                  <option value="en">English</option>
                </select>
              </div>

              {/* Notifications */}
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-[#f5f5f5] font-semibold mb-1">通知</p>
                  <p className="text-sm text-[#b0b0b0]">
                    エコー関連の通知を受け取る
                  </p>
                </div>
                <button
                  onClick={() => setNotifications(!notifications)}
                  className={`relative w-12 h-6 rounded-full transition-colors ${
                    notifications ? 'bg-[#50c878]' : 'bg-white/10'
                  }`}
                >
                  <div
                    className={`absolute w-5 h-5 bg-white rounded-full top-0.5 transition-transform ${
                      notifications ? 'translate-x-6' : 'translate-x-0.5'
                    }`}
                  />
                </button>
              </div>
            </div>
          </div>

          {/* Account Settings */}
          <div className="glass-morphism rounded-2xl p-6 sm:p-8">
            <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-6">
              アカウント設定
            </h2>

            <div className="space-y-4">
              <div className="pb-4 border-b border-white/10">
                <p className="text-sm text-[#b0b0b0] mb-2">メールアドレス</p>
                <p className="text-[#f5f5f5] font-semibold">user@example.com</p>
              </div>

              <div className="pb-4 border-b border-white/10">
                <p className="text-sm text-[#b0b0b0] mb-2">登録日</p>
                <p className="text-[#f5f5f5] font-semibold">
                  2026年2月24日
                </p>
              </div>

              <div className="pt-4">
                <button className="button-secondary px-6 py-3 text-base">
                  パスワードを変更
                </button>
              </div>
            </div>
          </div>

          {/* Legal & Support */}
          <div className="glass-morphism rounded-2xl p-6 sm:p-8">
            <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-6">
              サポート
            </h2>

            <div className="space-y-3">
              <Link
                href="/terms"
                className="block px-4 py-3 rounded-lg hover:bg-white/5 transition-colors text-[#d4af37] hover:text-[#e8c547]"
              >
                利用規約
              </Link>
              <Link
                href="/privacy"
                className="block px-4 py-3 rounded-lg hover:bg-white/5 transition-colors text-[#d4af37] hover:text-[#e8c547]"
              >
                プライバシーポリシー
              </Link>
              <button className="w-full text-left px-4 py-3 rounded-lg hover:bg-white/5 transition-colors text-[#d4af37] hover:text-[#e8c547]">
                よくある質問
              </button>
              <button className="w-full text-left px-4 py-3 rounded-lg hover:bg-white/5 transition-colors text-[#d4af37] hover:text-[#e8c547]">
                お問い合わせ
              </button>
            </div>
          </div>

          {/* Danger Zone */}
          <div className="glass-morphism rounded-2xl p-6 sm:p-8 border-red-500/30">
            <h2 className="text-2xl font-serif font-bold text-red-400 mb-6">
              危険ゾーン
            </h2>

            <div className="space-y-4">
              <button
                onClick={handleLogout}
                className="w-full px-6 py-3 rounded-lg border border-[#d4af37] text-[#d4af37] hover:bg-[#d4af37]/10 transition-colors font-semibold"
              >
                ログアウト
              </button>

              <button className="w-full px-6 py-3 rounded-lg border border-red-500/50 text-red-400 hover:bg-red-500/10 transition-colors font-semibold">
                アカウントを削除
              </button>
            </div>
          </div>
        </div>

        {/* App Version */}
        <div className="mt-12 text-center text-[#606060]">
          <p className="text-sm">Echoria v1.0.0</p>
          <p className="text-xs mt-1">Build 2026.02.24</p>
        </div>
      </main>
    </div>
  );
}

export default function SettingsPage() {
  return (
    <AuthGuard>
      <SettingsPageContent />
    </AuthGuard>
  );
}
