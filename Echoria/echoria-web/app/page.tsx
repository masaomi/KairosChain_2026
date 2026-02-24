'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useEffect } from 'react';
import { isAuthenticated } from '@/lib/auth';

export default function LandingPage() {
  const router = useRouter();

  useEffect(() => {
    if (isAuthenticated()) {
      router.push('/home');
    }
  }, [router]);

  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] relative overflow-hidden">
      {/* Animated background elements */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-20 right-20 w-72 h-72 bg-[#50c878]/5 rounded-full blur-3xl animate-pulse-slow" />
        <div className="absolute bottom-20 left-20 w-96 h-96 bg-[#d4af37]/5 rounded-full blur-3xl animate-pulse-slow" />
      </div>

      {/* Content */}
      <div className="relative z-10 flex flex-col items-center justify-center min-h-screen px-4 sm:px-6 lg:px-8">
        {/* Logo/Title */}
        <div className="text-center mb-8 sm:mb-12">
          <h1 className="text-4xl sm:text-6xl font-serif font-bold text-gradient mb-4">
            Echoria
          </h1>
          <p className="text-lg sm:text-xl text-[#b0b0b0] mb-2">
            ティアラと紡ぐ、あなただけの物語
          </p>
          <p className="text-sm sm:text-base text-[#b0b0b0]">
            A story woven with Tiara, just for you
          </p>
        </div>

        {/* Description */}
        <div className="max-w-2xl mb-8 sm:mb-12 text-center">
          <p className="text-base sm:text-lg text-[#f5f5f5] leading-relaxed mb-4">
            あなたのエコー（AI人格）を育成し、猫の精霊ティアラのガイドのもとで、選択が物語を変えていく冒険へ。
          </p>
          <p className="text-sm sm:text-base text-[#b0b0b0]">
            Create your Echo, guide them through an interactive narrative where every choice matters, and bond with Tiara, your mystical cat spirit guide.
          </p>
        </div>

        {/* Feature highlights */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 sm:gap-6 max-w-3xl mb-12 sm:mb-16">
          <div className="glass-morphism p-4 sm:p-6 rounded-lg">
            <div className="text-2xl sm:text-3xl text-[#50c878] mb-2">✨</div>
            <h3 className="font-semibold text-[#d4af37] mb-2 text-sm sm:text-base">
              エコー育成
            </h3>
            <p className="text-xs sm:text-sm text-[#b0b0b0]">
              あなたの選択でAI人格を進化させよう
            </p>
          </div>

          <div className="glass-morphism p-4 sm:p-6 rounded-lg">
            <div className="text-2xl sm:text-3xl text-[#d4af37] mb-2">📖</div>
            <h3 className="font-semibold text-[#d4af37] mb-2 text-sm sm:text-base">
              物語の選択肢
            </h3>
            <p className="text-xs sm:text-sm text-[#b0b0b0]">
              分岐する冒険で運命を変える
            </p>
          </div>

          <div className="glass-morphism p-4 sm:p-6 rounded-lg">
            <div className="text-2xl sm:text-3xl text-[#50c878] mb-2">🐱</div>
            <h3 className="font-semibold text-[#d4af37] mb-2 text-sm sm:text-base">
              ティアラの絆
            </h3>
            <p className="text-xs sm:text-sm text-[#b0b0b0]">
              神秘の猫精との関係を深めよう
            </p>
          </div>
        </div>

        {/* CTA Buttons */}
        <div className="flex flex-col sm:flex-row gap-4 sm:gap-6">
          <Link
            href="/signup"
            className="button-primary text-sm sm:text-base text-center px-8 py-3 sm:py-4"
          >
            始める
          </Link>
          <Link
            href="/login"
            className="button-secondary text-sm sm:text-base text-center px-8 py-3 sm:py-4"
          >
            ログイン
          </Link>
        </div>

        {/* Footer links */}
        <div className="absolute bottom-6 sm:bottom-8 left-0 right-0 flex justify-center gap-4 sm:gap-6 text-xs sm:text-sm">
          <Link href="/terms" className="text-[#b0b0b0] hover:text-[#d4af37] transition-colors">
            利用規約
          </Link>
          <span className="text-[#404040]">•</span>
          <Link href="/privacy" className="text-[#b0b0b0] hover:text-[#d4af37] transition-colors">
            プライバシー
          </Link>
        </div>
      </div>
    </div>
  );
}
