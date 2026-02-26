'use client';

import { useState } from 'react';
import Link from 'next/link';
import { forgotPassword, resetPassword } from '@/lib/api';
import Button from '@/components/ui/Button';
import { AlertCircle, CheckCircle, ArrowLeft } from 'lucide-react';

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState('');
  const [token, setToken] = useState('');
  const [password, setPassword] = useState('');
  const [passwordConfirmation, setPasswordConfirmation] = useState('');
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);
  const [step, setStep] = useState<'request' | 'reset'>('request');

  // Step 1: Request password reset token
  const handleRequestToken = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setSuccess('');
    setLoading(true);

    try {
      const response = await forgotPassword(email);
      setSuccess(response.message);
      // MVP: token is returned directly since no email service yet
      if (response.token) {
        setToken(response.token);
        setStep('reset');
      }
    } catch (err: any) {
      setError(err.message || 'エラーが発生しました。もう一度お試しください。');
    } finally {
      setLoading(false);
    }
  };

  // Step 2: Reset password with token
  const handleResetPassword = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setSuccess('');

    if (password !== passwordConfirmation) {
      setError('パスワードが一致しません。');
      return;
    }

    setLoading(true);

    try {
      const response = await resetPassword(token, password, passwordConfirmation);
      setSuccess(response.message);
      setStep('request');
      setEmail('');
      setToken('');
      setPassword('');
      setPasswordConfirmation('');
    } catch (err: any) {
      setError(err.message || 'パスワードのリセットに失敗しました。');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] flex items-center justify-center px-4 sm:px-6 lg:px-8 relative">
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
              {step === 'request' ? 'パスワードをリセット' : '新しいパスワードを設定'}
            </p>
          </div>

          {/* Error Message */}
          {error && (
            <div className="mb-6 p-4 rounded-lg bg-red-900/20 border border-red-500/30 flex gap-3">
              <AlertCircle className="w-5 h-5 text-red-400 flex-shrink-0 mt-0.5" />
              <p className="text-sm text-red-200">{error}</p>
            </div>
          )}

          {/* Success Message */}
          {success && (
            <div className="mb-6 p-4 rounded-lg bg-green-900/20 border border-green-500/30 flex gap-3">
              <CheckCircle className="w-5 h-5 text-green-400 flex-shrink-0 mt-0.5" />
              <p className="text-sm text-green-200">{success}</p>
            </div>
          )}

          {/* Step 1: Request Token */}
          {step === 'request' && (
            <form onSubmit={handleRequestToken} className="space-y-5">
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

              <Button
                type="submit"
                disabled={loading}
                className="w-full button-primary py-3 text-base"
              >
                {loading ? '送信中...' : 'リセットリンクを送信'}
              </Button>
            </form>
          )}

          {/* Step 2: Reset Password */}
          {step === 'reset' && (
            <form onSubmit={handleResetPassword} className="space-y-5">
              <div className="p-3 rounded-lg bg-[#d4af37]/10 border border-[#d4af37]/20">
                <p className="text-xs text-[#d4af37]">
                  MVP: トークンが自動で設定されました。本番環境ではメールで送信されます。
                </p>
              </div>

              <div>
                <label htmlFor="password" className="block text-sm font-medium text-[#d4af37] mb-2">
                  新しいパスワード
                </label>
                <input
                  id="password"
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  required
                  minLength={8}
                  className="w-full px-4 py-3 rounded-lg bg-white/5 border border-white/10 text-[#f5f5f5] placeholder-[#606060] focus:outline-none focus:border-[#d4af37]/50 focus:ring-1 focus:ring-[#d4af37]/20 transition-all"
                  placeholder="••••••••"
                />
              </div>

              <div>
                <label htmlFor="password-confirmation" className="block text-sm font-medium text-[#d4af37] mb-2">
                  パスワード確認
                </label>
                <input
                  id="password-confirmation"
                  type="password"
                  value={passwordConfirmation}
                  onChange={(e) => setPasswordConfirmation(e.target.value)}
                  required
                  minLength={8}
                  className="w-full px-4 py-3 rounded-lg bg-white/5 border border-white/10 text-[#f5f5f5] placeholder-[#606060] focus:outline-none focus:border-[#d4af37]/50 focus:ring-1 focus:ring-[#d4af37]/20 transition-all"
                  placeholder="••••••••"
                />
              </div>

              <Button
                type="submit"
                disabled={loading}
                className="w-full button-primary py-3 text-base"
              >
                {loading ? '更新中...' : 'パスワードを更新'}
              </Button>

              <button
                type="button"
                onClick={() => { setStep('request'); setError(''); setSuccess(''); }}
                className="w-full text-sm text-[#b0b0b0] hover:text-[#d4af37] transition-colors"
              >
                メールアドレスを再入力
              </button>
            </form>
          )}

          {/* Back to Login Link */}
          <div className="mt-6 text-center">
            <Link
              href="/login"
              className="inline-flex items-center gap-2 text-sm text-[#d4af37] hover:text-[#e8c547] transition-colors font-semibold"
            >
              <ArrowLeft className="w-4 h-4" />
              ログインに戻る
            </Link>
          </div>
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
