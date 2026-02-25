'use client';

import { Sparkles } from 'lucide-react';
import { Affinity } from '@/types';

const AXIS_LABELS: Record<string, string> = {
  tiara_trust: '信頼',
  logic_empathy_balance: '共感',
  name_memory_stability: '記憶',
  authority_resistance: '反抗',
  fragment_count: 'カケラ',
};

interface AffinityIndicatorProps {
  delta: Partial<Affinity>;
}

export default function AffinityIndicator({ delta }: AffinityIndicatorProps) {
  if (!delta) return null;

  const entries = Object.entries(delta).filter(
    ([, val]) => typeof val === 'number' && val !== 0
  );

  if (entries.length === 0) return null;

  return (
    <div className="bg-[#d4af37]/10 border-t border-[#d4af37]/30 px-4 py-3">
      <div className="flex items-center justify-center gap-3 flex-wrap">
        <Sparkles className="w-3.5 h-3.5 text-[#d4af37]" />
        {entries.map(([key, val]) => {
          const label = AXIS_LABELS[key] || key;
          const isPositive = (val as number) > 0;
          return (
            <span
              key={key}
              className={`text-xs font-medium ${
                isPositive ? 'text-[#50c878]' : 'text-red-300'
              }`}
            >
              {label} {isPositive ? '+' : ''}
              {val}
            </span>
          );
        })}
      </div>
    </div>
  );
}
