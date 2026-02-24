'use client';

import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { signup, googleAuth } from '@/lib/api';
import { setToken } from '@/lib/auth';
import Button from '@/components/ui/Button';
import { AlertCircle } from 'lucide-react';

export default function SignupPage() {
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [agreeToTerms, setAgreeToTerms] = useState(false);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');

    if (password !== confirmPassword) {
      setError('パスワードが一致しません');
      return;
    }

    if (!agreeToTerms) {
      setError('利用規約とプライバシーポリシーに同意してください');
      return;
    }

    setLoading(true);

    try {
      const response = await signup(name, email, password);
      setToken(response.token);
      router.push('/home');
    } catch (err: any) {
      setError(
        err.message || '登録に失敗しました。もう一度お試しください。'
      );
    } finally {
      setLoading(false);
    }
  };

  const handleGoogleAuth = async () => {
    setError('');
    setLoading(true);
    try {
      const response = await googleAuth('google_token');
      setToken(response.token);
      router.push('/home');
    } catch (err: any) {
      setError('Google認証に失敗しました。もう一度お試しください。');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] flex items-center justify-center px-4 sm:px-6 lg:px-8 py-8 sm:py-12 relative">
      {/* Background decoration */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-10 right-10 w-64 h-64 bg-[#50c878]/5 rounded-full blur-3xl" />
        <div className="absolute bottom-10 left-10 w-80 h-80 bg-[#d4af37]/5 rounded-full blur-3xl" />
      </div>

      {/* Form Container */}
      <div className="relative z-10 w-full max-w-md">
        <div className="glass-morphism rounded-2xl p-8 sm:p-10">
          {/* Header */}
          <div className="text-center mb-8">
            <h1 className="text-3xl sm:text-4xl font-serif font-bold text-[#d4af37] mb-2">
              Echoria
            </h1>
            <p className="text-[#b0b0b0] text-sm sm:text-base">
              新しいアカウントを作成
            </p>
          </div>

          {/* Error Message */}
          {error && (
            <div className="mb-6 p-4 rounded-lg bg-red-900/20 border border-red-500/30 flex gap-3">
              <AlertCircle className="w-5 h-5 text-red-400 flex-shrink-0 mt-0.5" />
              <p className="text-sm text-red-200">{error}</p>
            </div>
          )}

          {/* Signup Form */}
          <form onSubmit={handleSubmit} className="space-y-5">
            <div>
              <label htmlFor="name" className="block text-sm font-medium text-[#d4af37] mb-2">
                名前
              </label>
              <input
                id="name"
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
                className="w-full px-4 py-3 rounded-lg bg-white/5 border border-white/10 text-[#f5f5f5] placeholder-[#606060] focus:outline-none focus:border-[#d4af37]/50 focus:ring-1 focus:ring-[#d4af37]/20 transition-all"
                placeholder="あなたの名前"
              />
            </div>

            <div>
              <label htmlFor="email" className="block text-sm font-medium text-[#d4af37] mb-2">
                メールアドレス
              </label>
              <input
                id="email"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
                className="w-full px-4 py-3 rounded-lg bg-white/5 border border-white/10 text-[#f5f5f5] placeholder-[#606060] focus:outline-none focus:border-[#d4af37]/50 focus:ring-1 focus:ring-[#d4af37]/20 transition-all"
                placeholder="your@email.com"
              />
            </div>

            <div>
              <label htmlFor="password" className="block text-sm font-medium text-[#d4af37] mb-2">
                パスワード
              </label>
              <input
                id="password"
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                required
                minLength={8}
                className="w-full px-4 py-3 rounded-lg bg-white/5 border border-white/10 text-[#f5f5f5] placeholder-[#606060] focus:outline-none focus:border-[#d4af37]/50 focus:ring-1 focus:ring-[#d4af37]/20 transition-all"
                placeholder="8文字以上"
              />
            </div>

            <div>
              <label htmlFor="confirm-password" className="block text-sm font-medium text-[#d4af37] mb-2">
                パスワード（確認）
              </label>
              <input
                id="confirm-password"
                type="password"
                value={confirmPassword}
                onChange={(e) => setConfirmPassword(e.target.value)}
                required
                minLength={8}
                className="w-full px-4 py-3 rounded-lg bg-white/5 border border-white/10 text-[#f5f5f5] placeholder-[#606060] focus:outline-none focus:border-[#d4af37]/50 focus:ring-1 focus:ring-[#d4af37]/20 transition-all"
                placeholder="パスワードを再入力"
              />
            </div>

            {/* Terms Checkbox */}
            <div className="flex items-start gap-3 pt-2">
              <input
                id="terms"
                type="checkbox"
                checked={agreeToTerms}
                onChange={(e) => setAgreeToTerms(e.target.checked)}
                className="w-4 h-4 mt-1 rounded accent-[#d4af37] cursor-pointer"
              />
              <label htmlFor="terms" className="text-xs sm:text-sm text-[#b0b0b0] cursor-pointer">
                <Link href="/terms" className="text-[#d4af37] hover:text-[#e8c547]">
                  利用規約
                </Link>
                {' '}と{' '}
                <Link href="/privacy" className="text-[#d4af37] hover:text-[#e8c547]">
                  プライバシーポリシー
                </Link>
                に同意します
              </label>
            </div>

            <Button
              type="submit"
              disabled={loading}
              className="w-full button-primary py-3 text-base"
            >
              {loading ? '登録中...' : '登録する'}
            </Button>
          </form>

          {/* Divider */}
          <div className="my-6 flex items-center gap-3">
            <div className="flex-1 h-px bg-white/10" />
            <span className="text-xs text-[#b0b0b0]">or</span>
            <div className="flex-1 h-px bg-white/10" />
          </div>

          {/* Google Auth */}
          <button
            onClick={handleGoogleAuth}
            disabled={loading}
            className="w-full px-4 py-3 rounded-lg border border-white/10 text-[#f5f5f5] hover:bg-white/5 transition-colors disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
          >
            <svg className="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
              <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" fill="#4285F4"/>
              <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" fill="#34A853"/>
              <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" fill="#FBBC05"/>
              <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" fill="#EA4335"/>
            </svg>
            <span className="text-sm sm:text-base">Googleで登録</span>
          </button>

          {/* Login Link */}
          <p className="text-center text-sm text-[#b0b0b0] mt-6">
            既にアカウントをお持ちの方は{' '}
            <Link
              href="/login"
              className="text-[#d4af37] hover:text-[#e8c547] transition-colors font-semibold"
            >
              ここ
            </Link>
          </p>
        </div>

        {/* Footer */}
        <div className="text-center mt-6 text-xs text-[#606060]">
          <Link href="/terms" className="hover:text-[#b0b0b0] transition-colors mr-4">
            利用規約
          </Link>
          <Link href="/privacy" className="hover:text-[#b0b0b0] transition-colors">
            プライバシー
          </Link>
        </div>
      </div>
    </div>
  );
}
