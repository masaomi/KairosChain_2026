'use client';

import { useState, useEffect } from 'react';
import { Sparkles } from 'lucide-react';

const ONBOARDING_KEY = 'echoria_story_onboarding_seen';

interface StoryOnboardingProps {
  echoName: string;
  onComplete: () => void;
}

export default function StoryOnboarding({ echoName, onComplete }: StoryOnboardingProps) {
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const seen = localStorage.getItem(ONBOARDING_KEY);
    if (!seen) {
      setVisible(true);
    } else {
      onComplete();
    }
  }, [onComplete]);

  const handleStart = () => {
    localStorage.setItem(ONBOARDING_KEY, 'true');
    setVisible(false);
    onComplete();
  };

  if (!visible) return null;

  return (
    <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 px-4">
      <div className="glass-morphism rounded-2xl p-8 sm:p-10 max-w-lg w-full text-center animate-fade-in">
        <Sparkles className="w-8 h-8 text-[#d4af37] mx-auto mb-4" />

        <h2 className="text-xl sm:text-2xl font-serif text-[#d4af37] mb-6">
          残響界へようこそ
        </h2>

        <div className="space-y-4 text-left text-sm sm:text-base text-[#e0e0e0] leading-relaxed mb-8">
          <p>
            あなたはこれから、記憶を失った存在
            <span className="text-[#d4af37] font-medium">「{echoName}」</span>
            として目覚めます。
          </p>

          <p>
            猫の精霊
            <span className="text-[#c0a0d0] font-medium">ティアラ</span>
            があなたの伴侶となり、旅を導きます。
          </p>

          <p className="border-l-2 border-[#50c878]/50 pl-3 text-[#b0b0b0]">
            あなたの選択が、エコーの心を形作ります。
            信頼、共感、記憶、意志——すべてがあなたの決断から生まれます。
          </p>

          <p className="text-[#808080] text-xs">
            物語はいつでも中断・再開できます。
          </p>
        </div>

        <button
          onClick={handleStart}
          className="button-primary px-8 py-3 text-base"
        >
          物語を始める
        </button>
      </div>
    </div>
  );
}
