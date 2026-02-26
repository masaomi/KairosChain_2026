import { BeaconChoice } from '@/types';

interface ChoicePanelProps {
  choices: BeaconChoice[];
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
    </div>
  );
}
