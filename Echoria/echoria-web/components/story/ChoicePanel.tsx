import { Choice } from '@/types';

interface ChoicePanelProps {
  choices: Choice[];
  onSelect: (index: number) => void;
  disabled?: boolean;
}

export default function ChoicePanel({ choices, onSelect, disabled }: ChoicePanelProps) {
  if (!choices || choices.length === 0) {
    return null;
  }

  return (
    <div className="glass-morphism rounded-2xl p-6 sm:p-8">
      <p className="text-[#b0b0b0] text-sm mb-6 text-center">どの道を選びますか？</p>

      <div className="space-y-3">
        {choices.map((choice, idx) => (
          <button
            key={idx}
            onClick={() => onSelect(idx)}
            disabled={disabled}
            className="w-full p-4 text-left rounded-lg border border-[#d4af37] hover:bg-[#d4af37]/10 transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed group"
          >
            <div className="flex items-start gap-3">
              <span className="flex-shrink-0 w-6 h-6 rounded-full border-2 border-[#d4af37] flex items-center justify-center text-xs text-[#d4af37] group-hover:bg-[#d4af37]/20 transition-colors">
                {idx + 1}
              </span>
              <span className="text-[#f5f5f5] group-hover:text-[#d4af37] transition-colors">
                {choice.text}
              </span>
            </div>
            {choice.consequence && (
              <p className="text-xs text-[#b0b0b0] mt-2 ml-9">
                {choice.consequence}
              </p>
            )}
          </button>
        ))}
      </div>
    </div>
  );
}
