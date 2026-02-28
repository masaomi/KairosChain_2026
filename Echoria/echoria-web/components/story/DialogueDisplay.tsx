'use client';

import { DialogueLine } from '@/types';

interface DialogueDisplayProps {
  dialogue: DialogueLine[];
  visible: boolean;
  partnerName?: string;
}

// Map tone to visual style
const toneStyles: Record<string, string> = {
  playful: 'text-[#50c878]',
  gentle: 'text-[#a8d8ea]',
  teasing: 'text-[#50c878]',
  humorous: 'text-[#50c878]',
  solemn: 'text-[#c0a0d0]',
  whisper: 'text-[#b0b0b0] italic',
  contemplative: 'text-[#b0b0b0]',
  thoughtful: 'text-[#a8d8ea]',
  sad: 'text-[#c0a0d0]',
  warm: 'text-[#e8c547]',
  silent_contemplation: 'text-[#808080] italic',
};

function getSpeakerStyle(speaker: string, partnerName: string = 'ティアラ'): { color: string; label: string; align: string } {
  if (speaker === partnerName || speaker === 'ティアラ' || speaker === 'Tiara') {
    return {
      color: 'text-[#c0a0d0]',
      label: partnerName,
      align: 'justify-start',
    };
  }
  if (speaker === 'エコー' || speaker === 'Echo') {
    return {
      color: 'text-[#d4af37]',
      label: 'エコー',
      align: 'justify-end',
    };
  }
  // NPC
  return {
    color: 'text-[#a8d8ea]',
    label: speaker,
    align: 'justify-start',
  };
}

export default function DialogueDisplay({ dialogue, visible, partnerName }: DialogueDisplayProps) {
  if (!dialogue || dialogue.length === 0 || !visible) {
    return null;
  }

  return (
    <div className="space-y-4 my-6">
      {dialogue.map((line, idx) => {
        const speakerStyle = getSpeakerStyle(line.speaker, partnerName || 'ティアラ');
        const toneClass = toneStyles[line.tone || ''] || 'text-[#f5f5f5]';
        const isEcho = line.speaker === 'エコー' || line.speaker === 'Echo';

        return (
          <div
            key={idx}
            className={`flex ${speakerStyle.align} animate-fade-in`}
            style={{ animationDelay: `${idx * 200}ms` }}
          >
            <div
              className={`max-w-[85%] ${
                isEcho ? 'bg-[#d4af37]/10 border-[#d4af37]/30' : 'bg-white/5 border-white/10'
              } border rounded-xl px-5 py-3`}
            >
              <span className={`text-xs font-medium ${speakerStyle.color} block mb-1`}>
                {speakerStyle.label}
              </span>
              <p className={`text-base sm:text-lg leading-relaxed ${toneClass}`}>
                「{line.text}」
              </p>
            </div>
          </div>
        );
      })}
    </div>
  );
}
