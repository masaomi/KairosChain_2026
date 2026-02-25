import { BeaconChoice } from '@/types';

interface ChoicePanelProps {
  choices: BeaconChoice[];
  onSelect: (index: number) => void;
  disabled?: boolean;
}

// Axis name translations for affinity display
const AXIS_LABELS: Record<string, string> = {
  tiara_trust: '信頼',
  logic_empathy_balance: '共感',
  name_memory_stability: '記憶',
  authority_resistance: '反抗',
  fragment_count: 'カケラ',
};

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
            className="w-full p-4 text-left rounded-lg border border-[#d4af37]/40 hover:border-[#d4af37] hover:bg-[#d4af37]/10 transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed group"
          >
            <div className="flex items-start gap-3">
              <span className="flex-shrink-0 w-6 h-6 rounded-full border-2 border-[#d4af37] flex items-center justify-center text-xs text-[#d4af37] group-hover:bg-[#d4af37]/20 transition-colors">
                {idx + 1}
              </span>
              <div className="flex-1">
                <span className="text-[#f5f5f5] group-hover:text-[#d4af37] transition-colors">
                  {choice.choice_text}
                </span>
                {/* Show affinity hints on hover */}
                {choice.affinity_delta && (
                  <div className="mt-2 flex flex-wrap gap-1.5 opacity-0 group-hover:opacity-100 transition-opacity">
                    {Object.entries(choice.affinity_delta).map(([key, val]) => {
                      if (!val || val === 0) return null;
                      const label = AXIS_LABELS[key] || key;
                      const isPositive = val > 0;
                      return (
                        <span
                          key={key}
                          className={`text-xs px-1.5 py-0.5 rounded ${
                            isPositive
                              ? 'bg-[#50c878]/20 text-[#50c878]'
                              : 'bg-red-500/20 text-red-300'
                          }`}
                        >
                          {label} {isPositive ? '+' : ''}{val}
                        </span>
                      );
                    })}
                  </div>
                )}
              </div>
            </div>
          </button>
        ))}
      </div>
    </div>
  );
}
