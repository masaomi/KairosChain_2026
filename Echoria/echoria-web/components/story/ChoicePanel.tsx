'use client';

import { useState } from 'react';
import { BeaconChoice } from '@/types';

const FREE_TEXT_MIN = 10;
const FREE_TEXT_MAX = 200;

interface ChoicePanelProps {
  choices: BeaconChoice[];
  onSelect: (index: number) => void;
  disabled?: boolean;
  allowFreeText?: boolean;
  onFreeTextSubmit?: (text: string) => void;
}

export default function ChoicePanel({
  choices,
  onSelect,
  disabled,
  allowFreeText,
  onFreeTextSubmit,
}: ChoicePanelProps) {
  const [freeTextOpen, setFreeTextOpen] = useState(false);
  const [freeText, setFreeText] = useState('');

  if (!choices || choices.length === 0) {
    return null;
  }

  const charCount = freeText.length;
  const isValidLength = charCount >= FREE_TEXT_MIN && charCount <= FREE_TEXT_MAX;

  const handleFreeTextSubmit = () => {
    if (!isValidLength || disabled || !onFreeTextSubmit) return;
    onFreeTextSubmit(freeText.trim());
    setFreeText('');
    setFreeTextOpen(false);
  };

  return (
    <div className="glass-morphism rounded-2xl p-6 sm:p-8">
      <p className="text-[#b0b0b0] text-sm mb-6 text-center">どの道を選びますか？</p>

      <div className="space-y-3">
        {choices.map((choice, idx) => (
          <button
            key={choice.choice_id || idx}
            onClick={() => onSelect(idx)}
            disabled={disabled}
            className="w-full p-4 min-h-[44px] text-left rounded-lg border border-[#d4af37]/40 hover:border-[#d4af37] hover:bg-[#d4af37]/10 transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed group"
          >
            <div className="flex items-start gap-3">
              <span className="flex-shrink-0 w-8 h-8 rounded-full border-2 border-[#d4af37] flex items-center justify-center text-xs text-[#d4af37] group-hover:bg-[#d4af37]/20 transition-colors">
                {idx + 1}
              </span>
              <span className="text-[#f5f5f5] group-hover:text-[#d4af37] transition-colors">
                {choice.choice_text}
              </span>
            </div>
          </button>
        ))}
      </div>

      {/* Free-text input section */}
      {allowFreeText && onFreeTextSubmit && (
        <div className="mt-6">
          {!freeTextOpen ? (
            <button
              onClick={() => setFreeTextOpen(true)}
              disabled={disabled}
              className="w-full p-4 min-h-[44px] text-center rounded-lg border-2 border-dashed border-[#50c878]/40 hover:border-[#50c878] hover:bg-[#50c878]/5 transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed text-[#50c878]/80 hover:text-[#50c878]"
            >
              自分の言葉で応える...
            </button>
          ) : (
            <div className="rounded-lg border border-[#50c878]/40 bg-white/5 p-4">
              <textarea
                value={freeText}
                onChange={(e) => setFreeText(e.target.value)}
                disabled={disabled}
                placeholder="エコーとして、あなたの言葉を紡いでください..."
                maxLength={FREE_TEXT_MAX}
                rows={3}
                className="w-full bg-transparent text-[#f5f5f5] placeholder-[#606060] resize-none outline-none text-base leading-relaxed"
                autoFocus
              />
              <div className="flex items-center justify-between mt-3 pt-3 border-t border-white/10">
                <span
                  className={`text-xs ${
                    charCount < FREE_TEXT_MIN
                      ? 'text-[#606060]'
                      : charCount > FREE_TEXT_MAX
                        ? 'text-red-400'
                        : 'text-[#50c878]'
                  }`}
                >
                  {charCount}/{FREE_TEXT_MAX}
                  {charCount < FREE_TEXT_MIN && (
                    <span className="ml-1">（あと{FREE_TEXT_MIN - charCount}文字）</span>
                  )}
                </span>
                <div className="flex items-center gap-3">
                  <button
                    onClick={() => {
                      setFreeTextOpen(false);
                      setFreeText('');
                    }}
                    disabled={disabled}
                    className="text-xs text-[#b0b0b0] hover:text-[#f5f5f5] transition-colors min-h-[36px] px-3"
                  >
                    戻る
                  </button>
                  <button
                    onClick={handleFreeTextSubmit}
                    disabled={disabled || !isValidLength}
                    className="px-5 py-2 min-h-[36px] rounded-full bg-[#50c878]/20 border border-[#50c878]/40 text-[#50c878] hover:bg-[#50c878]/30 hover:border-[#50c878] transition-all text-sm font-medium disabled:opacity-40 disabled:cursor-not-allowed"
                  >
                    言葉を紡ぐ
                  </button>
                </div>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
